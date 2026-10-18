# Rebuilds the pi-sandbox image when a newer pi or rtk release exists.
# Runs on the host (the container is ephemeral: docker run --rm).
#   -Status : fast check, prints "up-to-date" or "stale:<what>"
#   (default): rebuild if stale (started hidden by pi.ps1)
param([switch]$Status)
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Legacy'
$DIR = $PSScriptRoot
. (Join-Path $DIR 'lib\pi-sandbox.ps1')

# IMAGE / VOLUME from the same file pi.ps1 reads, so both always agree.
. (Initialize-Config $DIR)
if (-not $IMAGE) { $IMAGE = 'pi-sandbox' }
if (-not $VOLUME) { $VOLUME = 'pi-agent-home' }
$DOCKERFILE = Join-Path $DIR 'Dockerfile.pi'
$LOCK = if ($env:PI_UPDATE_LOCK) { $env:PI_UPDATE_LOCK } else { Join-Path $env:TEMP 'pi-sandbox-update.lock' }

function Get-PiLatest {
  try { (Invoke-RestMethod -Uri 'https://pi.dev/api/latest-version' -TimeoutSec 2).version } catch { $null }
}
# /releases/latest skips pre-releases; empty on failure (offline, rate limit) -> never blocks a launch
function Get-RtkLatest {
  try { "$((Invoke-RestMethod -Uri 'https://api.github.com/repos/rtk-ai/rtk/releases/latest' -TimeoutSec 2).tag_name)".TrimStart('v') } catch { $null }
}
# Versions actually baked into the image (not the pins); one container start for both.
function Get-ImageVersions {
  $lines = @(Invoke-DockerQuiet run --rm --entrypoint bash $IMAGE -c 'pi --version; rtk --version')
  $rtk = if ($lines.Count -ge 2) { (-split $lines[1])[-1] } else { $null }
  return @{ Pi = $(if ($lines.Count -ge 1) { "$($lines[0])".Trim() }); Rtk = $rtk }
}

$lp = Get-PiLatest; $lr = Get-RtkLatest
function Get-StaleLabel($img) {
  $label = @()
  if ($lp -and $lp -ne $img.Pi) { $label += "pi v$lp" }
  if ($lr -and $lr -ne $img.Rtk) { $label += "rtk v$lr" }
  return $label -join ' + '
}

if ($Status) {
  if (-not (Test-Docker)) { Write-Output 'up-to-date'; exit 0 }  # can't check -> never block launch
  $label = Get-StaleLabel (Get-ImageVersions)
  if ($label) { Write-Output "stale:$label" } else { Write-Output 'up-to-date' }
  exit 0
}

# ====== rebuild ======
$LogDir = Join-Path $DIR 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LOG = Join-Path $LogDir "update-$(Get-Date -Format 'yyyy-MM-dd').log"
function Log([string]$m) { Add-Content -LiteralPath $LOG -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m" }

if (-not (Test-Docker)) { Log 'docker down, skip'; exit 0 }
$img = Get-ImageVersions
if (-not (Get-StaleLabel $img) -and $img.Pi) { exit 0 }  # image missing (no version) -> build anyway

if (-not (Enter-UpdateLock $LOCK)) { Log "rebuild already running (lock $LOCK), skip"; exit 0 }
Push-Location -LiteralPath $DIR
try {
  # Bump the pins (busts the docker/npm layer cache) then rebuild. On build
  # failure a pin stays bumped, but the next launch compares against the image's
  # real version -> still stale -> retry. Self-healing.
  $changed = @(); $piPin = $null; $rtkPin = $null; $h = @{}
  if ($lp -and $lp -ne $img.Pi) { $piPin = $lp; $changed += "pi v$lp" }
  if ($lr -and $lr -ne $img.Rtk) {
    # The tag is movable: pin the tarball hashes with the version. No checksums
    # -> no bump (a version without its hash would fail every rebuild).
    try {
      $c = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "https://github.com/rtk-ai/rtk/releases/download/v$lr/checksums.txt").Content
      if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
      $h = Get-RtkHashes $c
    } catch { }
    if ($h.X86 -and $h.Arm) { $rtkPin = $lr; $changed += "rtk v$lr" }
    else { Log "rtk v$lr checksums unavailable — not bumping" }
  }
  # UTF-8 without BOM both ways: Windows PowerShell's default ANSI mangles non-ASCII.
  Write-Utf8 $DOCKERFILE (Update-DockerfilePins (Read-Utf8 $DOCKERFILE) $piPin $rtkPin $h.X86 $h.Arm)

  # Remember the previous image's exact ID (never a global prune) and drop it once rebuilt.
  $old = "$(Invoke-DockerQuiet image inspect --format '{{.Id}}' $IMAGE)"
  $ErrorActionPreference = 'Continue'  # docker build writes progress on stderr
  # piped through Add-Content: `*>>` would write UTF-16 into a log Log() appends ANSI to
  & docker build -t $IMAGE -f Dockerfile.pi . 2>&1 | ForEach-Object { "$_" } | Add-Content -LiteralPath $LOG
  $ok = $LASTEXITCODE -eq 0
  $ErrorActionPreference = 'Stop'
  if ($ok) {
    Log "rebuilt $IMAGE → $(if ($changed) { $changed -join ' + ' } else { 'initial build' })"
    $new = "$(Invoke-DockerQuiet image inspect --format '{{.Id}}' $IMAGE)"
    if ($old -and $old -ne $new) {
      # Fails, harmlessly, while a session still runs on it -> removed next rebuild.
      # checked after rm: Docker Desktop's containerd store may already have dropped it
      Invoke-DockerQuiet image rm $old | Out-Null
      Invoke-DockerQuiet image inspect $old | Out-Null
      if ($LASTEXITCODE -ne 0) { Log "removed previous image $old" } else { Log "previous image in use, kept $old" }
    }
    # The pi hook is an rtk-generated template: refresh it to match the new binary.
    if ($rtkPin) {
      Invoke-DockerQuiet run --rm -e RTK_TELEMETRY_DISABLED=1 -v "${VOLUME}:/root/.pi/agent" --entrypoint bash $IMAGE -c 'rtk init -g --agent pi --auto-patch' | Out-Null
      if ($LASTEXITCODE -ne 0) { Log 'rtk hook refresh failed' }
    }
  } else {
    Log "build FAILED (pi=$($img.Pi)→$lp, rtk=$($img.Rtk)→$lr) — retry next launch"
  }
} finally {
  Pop-Location
  Remove-Item -LiteralPath $LOCK -Recurse -Force -ErrorAction SilentlyContinue
}
