# pi-sandbox setup on Windows (Docker Desktop). Run from PowerShell.
# Usage: .\install.ps1
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Legacy'  # PS 7.3+: keep the 5.1 quoting Q() relies on
. (Join-Path $PSScriptRoot 'lib\pi-sandbox.ps1')
Push-Location -LiteralPath $PSScriptRoot
try {

# IMAGE / VOLUME / RTK_VOLUME from the same file pi.ps1 reads.
$CONFIG = Initialize-Config $PSScriptRoot
. $CONFIG

# ====== 1. Check Docker (Docker Desktop) ======
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host '❌ docker not found.'
  Write-Host '   Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
  exit 1
}
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
  if (-not (Test-Docker)) { Write-Host ''; Write-Host '❌ Docker is not responding. Start Docker Desktop then re-run.'; exit 1 }
}
Write-Host "✓ Docker $(docker version --format '{{.Server.Version}}')"

# ====== 2. Pi image (Node 24 + pi pinned; auto-updated by update-pi-sandbox.ps1) ======
Write-Host "→ Building $IMAGE image…"
$ErrorActionPreference = 'Continue'  # docker build writes progress on stderr
docker build -t $IMAGE -f Dockerfile.pi .
$built = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($built -ne 0) { exit $built }
Write-Host '✓ Image ready'

# ====== 2b. rtk data volume (persists `rtk gain` history across launches) ======
Invoke-DockerQuiet volume create $RTK_VOLUME | Out-Null
Write-Host "✓ $RTK_VOLUME volume ready"

# ====== 3. Model & thinking config (settings.json) ======
# Seed a fresh volume only: re-running must not wipe packages installed with
# `!pi install` (they live in this same settings.json).
# Extensions: pi installs the packages declared in settings.json on first launch.
Write-Host '→ Installing model config (no default provider, pi asks on first run)…'
docker run --rm -v "${VOLUME}:/root/.pi/agent" -v (Q "$PSScriptRoot\config:/config:ro") --entrypoint bash $IMAGE -c 'mkdir -p /root/.pi/agent && if [ -f /root/.pi/agent/settings.json ]; then echo ''✓ Model config kept (existing extensions preserved)''; else cp /config/settings.json /root/.pi/agent/ && echo ''✓ Model config installed''; fi'

# ====== 3b. Migrate packages installed from git by older versions to npm ======
# Left in place, the npm copy (settings or DeepSeek merge) loads next to them:
# duplicate extensions and skill collisions.
docker run --rm -e PI_SKIP_VERSION_CHECK=1 -v "${VOLUME}:/root/.pi/agent" --entrypoint bash $IMAGE -c 'cd /root/.pi/agent && for p in DietrichGebert/ponytail:@dietrichgebert/ponytail psychobarge/pi-deepseek-peak:pi-deepseek-peak; do g=git:github.com/${p%%:*}; if grep -qF $g settings.json 2>/dev/null; then pi uninstall $g && pi install npm:${p#*:}; fi; done'

# ====== 4. rtk hook (global pi extension, into the persistent volume) ======
Write-Host '→ Installing rtk pi extension (compresses bash output for the agent)…'
docker run --rm -e RTK_TELEMETRY_DISABLED=1 -v "${VOLUME}:/root/.pi/agent" --entrypoint bash $IMAGE -c 'rtk init -g --agent pi --auto-patch'
Write-Host '✓ rtk extension installed'

# ====== 5. DeepSeek opt-in (default: off) ======
Write-Host ''
Write-Host 'DeepSeek is NOT installed by default.'
$want = Read-Host 'Add DeepSeek support (pi-deepseek-peak extension + deepseek model defaults + DEEPSEEK_API_KEY forwarding)? [y/N]'
if ($want -match '^[yY]') {
  # Merge, never overwrite: keeps the extensions already in settings.json.
  Write-Host '→ Installing deepseek model config (pi installs pi-deepseek-peak from it)…'
  docker run --rm -v "${VOLUME}:/root/.pi/agent" -v (Q "$PSScriptRoot\config:/config:ro") --entrypoint python3 $IMAGE /config/merge-deepseek-settings.py /root/.pi/agent/settings.json /config/settings.deepseek.json
  if ($API_KEYS -notcontains 'DEEPSEEK_API_KEY') {
    [IO.File]::AppendAllText($CONFIG, "`r`n`$API_KEYS += @('DEEPSEEK_API_KEY')   # added by install.ps1`r`n", (New-Object Text.UTF8Encoding $false))
    $API_KEYS += 'DEEPSEEK_API_KEY'
    Write-Host '✓ DEEPSEEK_API_KEY added to API_KEYS (pi.config.ps1)'
  }
}

# ====== 6. API keys -> Windows Credential Manager (never setx, never argv) ======
Write-Host ''
Write-Host 'API keys are stored in Windows Credential Manager (target "pi-sandbox:<NAME>").'
foreach ($k in $API_KEYS) {
  if (Read-StoredKey $k) { Write-Host "  ✓ $k already stored"; continue }
  $s = Read-Host "  $k (hidden input, Enter to skip)" -AsSecureString
  if ($s.Length -eq 0) { continue }
  # A failed write must not stop the install: the launcher below still matters.
  try { Write-StoredKey $k $s; Write-Host "  ✓ $k stored" }
  catch { Write-Host "  ⚠ could not store $k ($($_.Exception.Message)) — re-run .\install.ps1 to add it later" }
  finally { $s.Dispose() }
}
foreach ($k in $API_KEYS) {
  if ([Environment]::GetEnvironmentVariable($k, 'User')) {
    Write-Host "⚠ $k is also a user env var (setx): it overrides Credential Manager and leaks to every process."
    Write-Host "   Remove it: [Environment]::SetEnvironmentVariable('$k', `$null, 'User')"
  }
}

# ====== 7. Launcher in PATH ======
$binDir = Join-Path $HOME '.pi\bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$shim = Join-Path $binDir 'pi.cmd'
$cmdLines = "@echo off`r`n`"$PSHOME\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\pi.ps1`" %*`r`n"
Set-Content -LiteralPath $shim -Value $cmdLines -Encoding ASCII
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath -or $userPath -notlike "*$binDir*") {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
  Write-Host "✓ Launcher installed: $shim"
  Write-Host '   → open a NEW terminal, then run "pi" from any allowed folder'
} else {
  Write-Host "✓ Launcher installed: $shim"
}

# ====== 7b. Git Bash launcher (`pi` bare command in Git Bash too) ======
# Cygwin/MSYS2 rule: a file starting with #! is executable without chmod.
$bashLauncher = Join-Path $binDir 'pi'
$bashContent = "#!/usr/bin/env bash`n" + 'exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PSScriptRoot + '\pi.ps1" "$@"' + "`n"
[IO.File]::WriteAllText($bashLauncher, $bashContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host '✓ Git Bash launcher installed (pi works from cmd, PowerShell and Git Bash — new window each)'

Write-Host ''
Write-Host 'To get started:'
Write-Host '  1. Edit pi.config.ps1 (allowed folders, API keys):  notepad pi.config.ps1'
Write-Host '  2. cd into one of the allowed folders, then:        pi'

# ====== Retention: keep 30 days ======
New-Item -ItemType Directory -Force -Path logs | Out-Null
Get-ChildItem logs -Filter '*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue

} finally { Pop-Location }
