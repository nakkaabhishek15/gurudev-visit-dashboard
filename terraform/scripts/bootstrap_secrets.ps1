# One-time bootstrap: create the two database roles and write the three runtime
# secrets. Run once, after `tofu apply`, with .\connect.ps1 open in another window.
#
#   .\terraform\scripts\bootstrap_secrets.ps1
#
# Passwords are generated here and go straight into Secrets Manager. They are
# never printed, never written to a file that outlives the run, and never passed
# as command-line arguments (which would be visible in the process list).

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
$dbName = $config['DB_NAME']
$dbUser = $config['DB_USER']
$dbPassword = $config['DB_PASSWORD']

function New-Password([int]$length) {
  $alphabet = ([char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')
  # Alphanumeric only: these end up inside a postgres:// URL, and escaping rules
  # for punctuation in connection strings are a reliable source of 3am outages.
  -join (1..$length | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
}

$readerPassword = New-Password 40
$appPassword = New-Password 40
$sessionSecret = New-Password 64

Write-Host "Creating database roles through the tunnel on localhost:$localPort ..." -ForegroundColor Cyan

# gurudev_reader: the reports. SELECT on exactly three tables, nothing else, and
# deliberately no default privileges -- a new table in raw_data should not become
# readable without someone deciding it should.
#
# gurudev_app: the app's own accounts. CREATE on the database so migrations can
# build the `app` schema, which it then owns.
$sql = @"
CREATE ROLE gurudev_reader WITH LOGIN PASSWORD '$readerPassword';
GRANT CONNECT ON DATABASE $dbName TO gurudev_reader;
GRANT USAGE ON SCHEMA raw_data TO gurudev_reader;
GRANT SELECT ON raw_data.retreat_guru_programs TO gurudev_reader;
GRANT SELECT ON raw_data.retreat_guru_registrations TO gurudev_reader;
GRANT SELECT ON raw_data.retreat_guru_people TO gurudev_reader;

CREATE ROLE gurudev_app WITH LOGIN PASSWORD '$appPassword';
GRANT CONNECT ON DATABASE $dbName TO gurudev_app;
GRANT CREATE ON DATABASE $dbName TO gurudev_app;
"@

$sqlFile = Join-Path $env:TEMP ("gurudev-bootstrap-{0}.sql" -f [guid]::NewGuid())
try {
  [System.IO.File]::WriteAllText($sqlFile, $sql)
  $env:PGPASSWORD = $dbPassword
  # Piped, not redirected: PowerShell has no `<` input-redirection operator.
  Get-Content $sqlFile -Raw | docker run --rm -i -e PGPASSWORD -e PGCONNECT_TIMEOUT=15 postgres:16 `
    psql -h host.docker.internal -p $localPort -U $dbUser -d $dbName -v ON_ERROR_STOP=1 -q -f -
  if ($LASTEXITCODE -ne 0) { throw "Role creation failed. Is .\connect.ps1 running?" }
} finally {
  Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}

Write-Host "Roles created. Writing secrets ..." -ForegroundColor Cyan

$secrets = @{
  '/gurudev/prod/warehouse-database-url' = "postgresql://gurudev_reader:$readerPassword@${rdsHost}:5432/$dbName"
  '/gurudev/prod/database-url'           = "postgresql://gurudev_app:$appPassword@${rdsHost}:5432/$dbName"
  '/gurudev/prod/auth/session-secret'    = $sessionSecret
}

foreach ($name in $secrets.Keys) {
  # Via a short-lived file rather than --secret-string, so the value never lands
  # in the process list or in shell history. There is no /dev/stdin on Windows,
  # which is why this is a real temp file and not a pipe.
  $valueFile = Join-Path $env:TEMP ("gurudev-secret-{0}" -f [guid]::NewGuid())
  try {
    [System.IO.File]::WriteAllText($valueFile, $secrets[$name])
    aws secretsmanager put-secret-value `
      --secret-id $name --region $region `
      --secret-string ("file://{0}" -f $valueFile.Replace('\', '/')) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed writing $name" }
  } finally {
    Remove-Item $valueFile -Force -ErrorAction SilentlyContinue
  }
  Write-Host "  wrote $name" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. The plaintext passwords existed only in this process." -ForegroundColor Green
Write-Host "Retrieve them later with: aws secretsmanager get-secret-value --secret-id <name>"
