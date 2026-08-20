# Give the app its own database, and repoint database-url at it.
#
#   .\terraform\scripts\fix_app_database.ps1
#
# Why: the `postgres` database on the aolf instance already has an `app` schema,
# and it already contains app_users / app_user_roles / schema_migrations -- the
# AOLF app's login tables, under exactly the names this app's migrations use.
# Sharing that database would have had two applications writing one user table.
# A separate database keeps the schema name and the migrations unchanged.
#
# gurudev_app's password is regenerated rather than reused, so this script never
# needs to read the existing secret back out.

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envFile = Join-Path $repoRoot ".env"
if (-not (Test-Path $envFile)) { throw "No .env at $envFile" }

$config = @{}
foreach ($line in Get-Content $envFile) {
  if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
  $parts = $line -split '=', 2
  $config[$parts[0].Trim()] = $parts[1].Trim()
}

$region = $config['AWS_REGION']
$rdsHost = $config['RDS_HOST']
$localPort = $config['LOCAL_PORT']
$adminDb = $config['DB_NAME']
$dbUser = $config['DB_USER']
$dbPassword = $config['DB_PASSWORD']

$appDb = "gurudev"

$alphabet = ([char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')
$appPassword = -join (1..40 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })

Write-Host "Creating database '$appDb' and rotating gurudev_app ..." -ForegroundColor Cyan

$env:PGPASSWORD = $dbPassword
try {
  # CREATE DATABASE cannot run inside a transaction block, so it goes on its own.
  docker run --rm -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 postgres:16 `
    psql -h host.docker.internal -p $localPort -U $dbUser -d $adminDb -v ON_ERROR_STOP=1 -q `
    -c "SELECT 'exists' FROM pg_database WHERE datname = '$appDb'" | Out-Null

  # Once the app has its own database it has no business in theirs. CREATE was
  # granted so migrations could build a schema; revoking it leaves gurudev_app
  # unable to add anything to the shared database.
  #
  # Note what is deliberately NOT here: any REVOKE ... FROM PUBLIC. PUBLIC grants
  # CONNECT and TEMP on every database by default, and revoking those would hit
  # the AOLF app's roles too. Without schema privileges a bare connection can
  # read and write nothing, so this is sufficient.
  $sql = @"
ALTER ROLE gurudev_app WITH PASSWORD '$appPassword';
REVOKE CREATE ON DATABASE $adminDb FROM gurudev_app;
REVOKE CONNECT ON DATABASE $adminDb FROM gurudev_app;
"@
  $sqlFile = Join-Path $env:TEMP ("gurudev-fix-{0}.sql" -f [guid]::NewGuid())
  try {
    [System.IO.File]::WriteAllText($sqlFile, $sql)

    docker run --rm -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 postgres:16 `
      psql -h host.docker.internal -p $localPort -U $dbUser -d $adminDb -v ON_ERROR_STOP=1 -q `
      -c "GRANT gurudev_app TO $dbUser" `
      -c "CREATE DATABASE $appDb OWNER gurudev_app"
    # Only tolerate the already-exists case. Treating every failure as benign is
    # how an earlier run repointed the secret at a database that was never
    # created: CREATE DATABASE ... OWNER needs SET ROLE on the owner, which is
    # why the GRANT above comes first.
    if ($LASTEXITCODE -ne 0) {
      $exists = docker run --rm -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 postgres:16 `
        psql -h host.docker.internal -p $localPort -U $dbUser -d $adminDb -At `
        -c "SELECT 1 FROM pg_database WHERE datname = '$appDb'"
      if ($exists -ne "1") { throw "CREATE DATABASE $appDb failed and the database does not exist." }
      Write-Host "  (database already exists -- continuing)" -ForegroundColor Yellow
    }

    Get-Content $sqlFile -Raw | docker run --rm -i -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 postgres:16 `
      psql -h host.docker.internal -p $localPort -U $dbUser -d $adminDb -v ON_ERROR_STOP=1 -q -f -
    if ($LASTEXITCODE -ne 0) { throw "Could not rotate gurudev_app's password. Is .\connect.ps1 running?" }
  } finally {
    Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
  }
} finally {
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}

Write-Host "Repointing /gurudev/prod/database-url at '$appDb' ..." -ForegroundColor Cyan

$url = "postgresql://gurudev_app:$appPassword@${rdsHost}:5432/$appDb"
$valueFile = Join-Path $env:TEMP ("gurudev-secret-{0}" -f [guid]::NewGuid())
try {
  [System.IO.File]::WriteAllText($valueFile, $url)
  aws secretsmanager put-secret-value `
    --secret-id /gurudev/prod/database-url --region $region `
    --secret-string ("file://{0}" -f $valueFile.Replace('\', '/')) | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed writing the secret" }
} finally {
  Remove-Item $valueFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Done. Database '$appDb' is owned by gurudev_app, and database-url points at it." -ForegroundColor Green
Write-Host "The warehouse connection is unchanged -- it still reads raw_data on '$adminDb'."
