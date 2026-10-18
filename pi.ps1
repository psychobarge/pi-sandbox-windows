# Launches pi in an isolated Docker container (Windows/PowerShell).
#   - run from inside an allowed folder (pi.config.ps1) -> confined to that folder only
#   - run from anywhere else -> asks to whitelist the folder, else mounts all allowed
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Legacy'  # PS 7.3+: keep the 5.1 quoting Q() relies on

$LAUNCH_DIR = (Get-Location).ProviderPath
$SCRIPT_DIR = $PSScriptRoot
. (Join-Path $SCRIPT_DIR 'lib\pi-sandbox.ps1')

# Push/Pop, not Set-Location: `.\pi.ps1` from an open shell shares its location.
Push-Location -LiteralPath $SCRIPT_DIR
$KEYS = $null; $PROXY = $null; $NET = $null
try {
  # ====== Usage log (host-side errors only) ======
  $LogDir = Join-Path $SCRIPT_DIR 'logs'
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
  function Log-Error([string]$msg) {
    Add-Content -Path (Join-Path $LogDir "usage-$(Get-Date -Format 'yyyy-MM-dd').log") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
  }

  $CONFIG = Initialize-Config $SCRIPT_DIR
  . $CONFIG

  # Never mount the repo, a folder inside it or containing it, nor the launcher
  # or PowerShell profile folders: the agent could rewrite code the host runs.
  # Paths are canonical (junctions, 8.3 names, subst resolved), case ignored.
  $PROTECTED = Get-ProtectedPaths $SCRIPT_DIR
  $LAUNCH = Get-CanonicalPath $LAUNCH_DIR
  $ALLOWED_OK = @()
  foreach ($entry in $ALLOWED) {
    $d = Resolve-AllowedEntry $entry
    if (-not (Test-DriveLetterPath $d)) { Write-Host "⚠ skipping $entry (not a X:\ path)"; continue }
    if (Test-Protected $d $PROTECTED) { Write-Host "⚠ skipping $entry (is, is inside, or contains pi-sandbox-wsl or a launcher/profile folder)"; continue }
    $ALLOWED_OK += $d
  }

  # Are we inside an allowed folder? If so, confine to it.
  $START_DIR = $null
  foreach ($d in $ALLOWED_OK) {
    if (Test-PathInside $LAUNCH $d) { $START_DIR = $d; break }
  }

  $MOUNT_ARGS = @()
  if ($START_DIR) {
    $CTX = ConvertTo-ContainerPath $START_DIR
    Write-Host "→ Confined to: $START_DIR"
    $MOUNT_ARGS = @('-v', (Q "$START_DIR`:$CTX"))
    $START_REL = $LAUNCH.Substring($START_DIR.Length).TrimStart('\')
    $WORKDIR = if ($START_REL) { "$CTX/$($START_REL -replace '\\', '/')" } else { $CTX }
  } else {
    if (Test-Protected $LAUNCH $PROTECTED) { Write-Host "❌ refusing to mount ${LAUNCH}: it is, is inside, or contains pi-sandbox-wsl or a launcher/profile folder"; exit 1 }
    if (-not (Test-DriveLetterPath $LAUNCH)) { Write-Host "❌ refusing to mount ${LAUNCH}: only X:\ paths can be mounted"; exit 1 }
    Write-Host "⚠ $LAUNCH is not in ALLOWED (pi.config.ps1)"
    $ans = Read-Host 'Add this folder to ALLOWED and launch confined to it? [y/N]'
    if ($ans -match '^[yY]') {
      Add-AllowedFolder $CONFIG $LAUNCH $ALLOWED
      Write-Host '✓ Added to ALLOWED (pi.config.ps1), relaunching…'
      Set-Location -LiteralPath $LAUNCH_DIR   # finally's Pop-Location still restores the caller's location
      & $PSCommandPath
      exit $LASTEXITCODE
    }
    Write-Host '→ Mounting all allowed folders (add the folder to ALLOWED in pi.config.ps1 to confine)'
    $used = New-Object System.Collections.Generic.List[string]
    foreach ($d in $ALLOWED_OK) {
      if (-not (Test-Path -LiteralPath $d -PathType Container)) { Log-Error "folder not found: $d"; Write-Host "⚠ folder not found: $d"; continue }
      $name = Get-UniqueName (Split-Path -Leaf $d) $used
      $MOUNT_ARGS += @('-v', (Q "$d`:$WORKSPACE/$name"))
    }
    $WORKDIR = $WORKSPACE
  }

  # Models live in ~/.pi/agent/models.json: the repo's copy is mounted read-only
  # over the volume, so editing it needs only a relaunch.
  $MODELS_ARGS = @()
  $MODELS_FILE = Join-Path $SCRIPT_DIR 'config\models.json'
  if (Test-Path -LiteralPath $MODELS_FILE) { $MODELS_ARGS = @('-v', (Q "$MODELS_FILE`:/root/.pi/agent/models.json:ro")) }

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

  # Auto-update: rebuild the image in background if a newer pi or rtk release exists.
  # The container is ephemeral (docker run --rm), so the update must happen here.
  $Updater = Join-Path $SCRIPT_DIR 'update-pi-sandbox.ps1'
  Invoke-DockerQuiet image inspect $IMAGE | Out-Null
  if ($LASTEXITCODE -eq 0) {
    try { $status = & $Updater -Status 2>$null } catch { $status = 'up-to-date' }
    if ("$status" -like 'stale:*') {
      Write-Host "→ Mise à jour disponible ($("$status".Substring(6))) — en arrière-plan, redémarre pi pour l'utiliser."
      Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Updater`"" | Out-Null
    }
  } else {
    Write-Host "→ Image $IMAGE absente, construction…"
    & $Updater | Out-Null
  }

  # API keys: proxied ones reach only the sidecar, pi gets the value "proxy".
  $KEYS = Resolve-ApiKeys $API_KEYS
  $ENV_ARGS = $KEYS.EnvArgs; $PROXY_ENV = $KEYS.ProxyEnv

  # ====== keyproxy sidecar ======
  # Private network per session, fixed alias "keyproxy" (config/models.json
  # hardcodes http://keyproxy:8787/…); two sessions never share a sidecar.
  $NET_ARGS = @()
  if ($KEYS.Proxied) {
    if (Test-NetworkArg $DOCKER_ARGS) {
      Log-Error '--network/--net in DOCKER_ARGS conflicts with keyproxy'
      Write-Host '❌ --network in DOCKER_ARGS conflicts with keyproxy: remove it (see README)'
      exit 1
    }
    Remove-OrphanSidecars
    $OWNER = Get-OwnerTag
    $NET = "pi-net-$OWNER"; $PROXY = "pi-keyproxy-$OWNER"
    Invoke-DockerQuiet network create --label "pi-sandbox.owner=$OWNER" $NET | Out-Null
    # No -p: 8787 must never be reachable from the host, only from the session network.
    Invoke-DockerQuiet run -d --rm --name $PROXY --label "pi-sandbox.owner=$OWNER" --network $NET --network-alias keyproxy `
      --read-only --cap-drop ALL --security-opt no-new-privileges --user node `
      -v (Q "$SCRIPT_DIR\proxy\keyproxy.mjs:/keyproxy.mjs:ro") `
      @PROXY_ENV --entrypoint node $IMAGE /keyproxy.mjs | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 25; $i++) {  # 5 s max
      $out = Invoke-DockerQuiet logs $PROXY | Out-String
      if ($LASTEXITCODE -ne 0) { break }  # --rm: gone = crashed
      if ($out -match 'keyproxy listening') { $ready = $true; break }
      Start-Sleep -Milliseconds 200
    }
    if (-not $ready) {
      Log-Error 'keyproxy failed to start'
      Write-Host "❌ keyproxy failed to start (check: docker logs $PROXY)"
      exit 1
    }
    $NET_ARGS = @('--network', $NET)
  }

  # Tool caches stay in the volume: without XDG_CACHE_HOME they would be
  # re-downloaded on every launch (the container is ephemeral).
  & docker run --rm -it @NET_ARGS @ENV_ARGS -v "${VOLUME}:/root/.pi/agent" -e XDG_CACHE_HOME=/root/.pi/agent/cache @MODELS_ARGS -v "${RTK_VOLUME}:/root/.local/share/rtk" @MOUNT_ARGS -w (Q $WORKDIR) @DOCKER_ARGS $IMAGE
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    $img = "$(Invoke-DockerQuiet image inspect --format '{{.Id}}' $IMAGE)"
    Log-Error "session pi terminée en erreur (code $code, image $($img.Substring(0, [Math]::Min(19, $img.Length))))"
  }
  exit $code
} finally {
  if ($PROXY) { Invoke-DockerQuiet rm -f $PROXY | Out-Null }
  if ($NET) { Invoke-DockerQuiet network rm $NET | Out-Null }
  # keys this run put in $env: must not outlive it in the caller's shell
  if ($KEYS) { foreach ($k in $KEYS.Set) { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue } }
  Pop-Location
}
