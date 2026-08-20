# SSM port-forward tunnel to the AOLF RDS instance.
# Leave this window open while using the preview. Ctrl+C stops the tunnel.

$ErrorActionPreference = "Stop"

# .env.local first for anyone carrying one over from the standalone preview,
# then .env, which is what this repo uses.
$envFile = Join-Path $PSScriptRoot ".env.local"
if (-not (Test-Path $envFile)) {
  $envFile = Join-Path $PSScriptRoot ".env"
}
if (-not (Test-Path $envFile)) {
  throw "No .env found next to connect.ps1. It needs AWS_REGION, SSM_TARGET, RDS_HOST, RDS_PORT and LOCAL_PORT."
}

$config = @{}
foreach ($line in Get-Content $envFile) {
  if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
  $parts = $line -split '=', 2
  $config[$parts[0].Trim()] = $parts[1].Trim()
}

$sessionInput = [ordered]@{
  Target       = $config['SSM_TARGET']
  DocumentName = "AWS-StartPortForwardingSessionToRemoteHost"
  Parameters   = [ordered]@{
    host            = @($config['RDS_HOST'])
    portNumber      = @($config['RDS_PORT'])
    localPortNumber = @($config['LOCAL_PORT'])
  }
}

$sessionPath = Join-Path $PSScriptRoot "session.json"
[System.IO.File]::WriteAllText($sessionPath, ($sessionInput | ConvertTo-Json -Depth 4))
$fileUri = "file://$($sessionPath.Replace('\', '/'))"

Write-Host "Tunnel: localhost:$($config['LOCAL_PORT']) -> $($config['RDS_HOST']):$($config['RDS_PORT'])" -ForegroundColor Cyan
Write-Host "Keep this window open. Ctrl+C to stop.`n" -ForegroundColor Yellow

aws ssm start-session --cli-input-json $fileUri --region $config['AWS_REGION']
