# Launches pi in an isolated Docker container (Windows/PowerShell).
#   - run from inside an allowed folder (pi.config.ps1) -> confined to that folder only
#   - run from anywhere else -> asks to whitelist the folder, else mounts all allowed
$ErrorActionPreference = 'Stop'

$LAUNCH_DIR = (Get-Location).Path
$SCRIPT_DIR = $PSScriptRoot
Set-Location $SCRIPT_DIR

# ====== Usage log (host-side errors only) ======
$LogDir = Join-Path $SCRIPT_DIR 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
function Log-Error([string]$msg) {
  Add-Content -Path (Join-Path $LogDir "usage-$(Get-Date -Format 'yyyy-MM-dd').log") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
}

. (Join-Path $PSScriptRoot 'pi.config.ps1')

# E:\foo -> /e/foo (container path, so pi's footer shows the real location)
function To-ContainerPath([string]$p) {
  return ('/' + $p.Substring(0, 1).ToLowerInvariant() + $p.Substring(2)).Replace('\', '/')
}
# PS 5.1 native-arg quoting: args containing spaces must carry embedded quotes
function Q([string]$a) { if ($a -match ' ') { return '"' + $a + '"' } else { return $a } }
function Test-Docker {
  # PS 5.1: with $ErrorActionPreference='Stop', native stderr (docker down) throws
  # even with 2>$null — catch it so a stopped Docker just returns $false.
  try {
    $out = docker version --format '{{.Server.Version}}' 2>$null | Out-String
  } catch { return $false }
  return ($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace($out)
}
function Test-Image([string]$img) { docker image inspect $img 2>$null | Out-Null; return $LASTEXITCODE -eq 0 }
function Get-EnvVar([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name, 'User') }
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name, 'Machine') }
  return $v
}

# Are we inside an allowed folder? If so, confine to it.
$START_DIR = $null
$START_REL = ''
foreach ($dir in $ALLOWED) {
  $base = $dir.TrimEnd('\')
  if ($LAUNCH_DIR -eq $base -or $LAUNCH_DIR.StartsWith($base + '\')) {
    $START_DIR = $dir
    $START_REL = $LAUNCH_DIR.Substring($base.Length).TrimStart('\')
    break
  }
}

# API keys / env vars to forward (only those defined on this machine)
$ENV_ARGS = @()
foreach ($k in $API_KEYS) {
  $v = Get-EnvVar $k
  if ($v) { $ENV_ARGS += @('-e', (Q "$k=$v")) }
}

$MOUNT_ARGS = @()
$WORKDIR = $null
if ($START_DIR) {
  $CTX = To-ContainerPath $START_DIR
  Write-Host "→ Confined to: $START_DIR"
  $MOUNT_ARGS = @('-v', (Q "$START_DIR`:$CTX"))
  $WORKDIR = if ($START_REL) { "$CTX/$($START_REL -replace '\\', '/')" } else { $CTX }
} else {
  Write-Host "⚠ $LAUNCH_DIR is not in ALLOWED (pi.config.ps1)"
  $ans = Read-Host 'Add this folder to ALLOWED and launch confined to it? [y/N]'
  if ($ans -match '^[yY]') {
    $lines = Get-Content -LiteralPath .\pi.config.ps1
    $out = New-Object System.Collections.Generic.List[string]
    $in = $false
    foreach ($l in $lines) {
      if (-not $in -and $l -match '^\$ALLOWED\s*=\s*@\(') { $in = $true }
      if ($in -and $l -match '^\s*\)\s*$') { $out.Add("  `"$LAUNCH_DIR`""); $in = $false }
      $out.Add($l)
    }
    Set-Content -LiteralPath .\pi.config.ps1 -Value $out -Encoding UTF8
    Write-Host "✓ Added to ALLOWED (pi.config.ps1), relaunching…"
    $START_DIR = $LAUNCH_DIR
    $CTX = To-ContainerPath $START_DIR
    $MOUNT_ARGS = @('-v', (Q "$START_DIR`:$CTX"))
    $WORKDIR = $CTX
  } else {
    Write-Host '→ Mounting all allowed folders (add the folder to ALLOWED in pi.config.ps1 to confine)'
    foreach ($dir in $ALLOWED) {
      if (-not (Test-Path -LiteralPath $dir)) {
        Log-Error "folder not found: $dir"
        Write-Host "⚠ folder not found: $dir"
        exit 1
      }
      $MOUNT_ARGS += @('-v', (Q "$dir`:$WORKSPACE/$(Split-Path -LiteralPath $dir -Leaf)"))
    }
    $WORKDIR = $WORKSPACE
  }
}

# Make sure Docker is up (start Docker Desktop if needed)
if (-not (Test-Docker)) {
  Write-Host '→ Docker is not responding, starting Docker Desktop…'
  $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  if (Test-Path $dd) { Start-Process $dd | Out-Null }
  Write-Host -NoNewline '   waiting for Docker engine'
  for ($i = 0; $i -lt 30; $i++) {  # up to 60s: cold WSL2 boot is slow
    Start-Sleep 2
    Write-Host -NoNewline '.'
    if (Test-Docker) { Write-Host ' ✓'; break }
  }
  if (-not (Test-Docker)) { Write-Host ''; Log-Error 'Docker is not responding'; Write-Host '❌ Docker is not responding. Start Docker Desktop then retry.'; exit 1 }
}

# Auto-update: rebuild the image in background if a newer pi release exists.
# The container is ephemeral (docker run --rm), so the update must happen here.
$Updater = Join-Path $SCRIPT_DIR 'update-pi-sandbox.ps1'
if (Test-Image $IMAGE) {
  $status = & $Updater -Status 2>$null
  if (-not $status) { $status = 'up-to-date' }
  if ($status -like 'stale:*') {
    $latest = $status.Substring(6)
    Write-Host "→ Nouvelle version de pi (v$latest) disponible — mise à jour en arrière-plan, redémarre pi pour l'utiliser."
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Updater`"" | Out-Null
  }
} else {
  Write-Host "→ Image $IMAGE absente, construction…"
  & $Updater | Out-Null
}

& docker run --rm -it @ENV_ARGS -v "${VOLUME}:/root/.pi/agent" -v "${RTK_VOLUME}:/root/.local/share/rtk" @MOUNT_ARGS -w (Q $WORKDIR) @DOCKER_ARGS $IMAGE
$code = $LASTEXITCODE
if ($code -ne 0) { Log-Error "session pi terminée en erreur (code $code)" }
exit $code
