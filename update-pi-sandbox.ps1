# Rebuilds the pi-sandbox image when a newer pi release exists.
# Runs on the host (the container is ephemeral: docker run --rm).
#   -Status : fast check, prints "up-to-date" or "stale:<latest>"
#   (default): rebuild in background if stale (started hidden by pi.ps1)
param([switch]$Status)
$ErrorActionPreference = 'Stop'
$DIR = $PSScriptRoot
Set-Location $DIR

$LogDir = Join-Path $DIR 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Test-Docker {
  # PS 5.1: with $ErrorActionPreference='Stop', native stderr (docker down) throws
  # even with 2>$null — catch it so a stopped Docker just returns $false.
  try {
    $out = docker version --format '{{.Server.Version}}' 2>$null | Out-String
  } catch { return $false }
  return ($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace($out)
}
function Get-LatestVersion {
  try { (Invoke-RestMethod -Uri 'https://pi.dev/api/latest-version' -TimeoutSec 5).version } catch { $null }
}
function Get-ImageVersion {
  $v = docker run --rm pi-sandbox --version 2>$null | Out-String
  return $v.Trim()
}

if ($Status) {
  # can't check -> never block launch
  if (-not (Test-Docker)) { Write-Output 'up-to-date'; exit 0 }
  $latest = Get-LatestVersion
  $installed = Get-ImageVersion
  if (-not $latest -or $latest -eq $installed) { Write-Output 'up-to-date' }
  else { Write-Output "stale:$latest" }
  exit 0
}

# ====== rebuild ======
$LOG = Join-Path $LogDir "update-$(Get-Date -Format 'yyyy-MM-dd').log"
if (-not (Test-Docker)) { Add-Content $LOG "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] docker down, skip"; exit 0 }
$latest = Get-LatestVersion
$installed = Get-ImageVersion
if (-not $latest -or $latest -eq $installed) { exit 0 }

# lock: one rebuild at a time
$lock = Join-Path $env:TEMP 'pi-sandbox-update.lock'
if (Test-Path $lock) { exit 0 }
New-Item -ItemType Directory -Path $lock | Out-Null
try {
  # Bump the pin (busts the docker/npm layer cache) then rebuild.
  # On build failure the pin stays bumped, but next launch compares against
  # the image's real version -> still stale -> retry. Self-healing.
  $content = Get-Content -Raw -LiteralPath .\Dockerfile.pi
  $new = $content -replace '@earendil-works/pi-coding-agent@[0-9][0-9.]*', "@earendil-works/pi-coding-agent@$latest"
  Set-Content -LiteralPath .\Dockerfile.pi -Value $new -Encoding ASCII -NoNewline
  & docker build -t pi-sandbox -f Dockerfile.pi . *>> $LOG
  if ($LASTEXITCODE -eq 0) {
    Add-Content $LOG "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] rebuilt pi-sandbox → $latest"
  } else {
    Add-Content $LOG "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] build FAILED (image=$installed, target=$latest) — retry next launch"
  }
} finally {
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
