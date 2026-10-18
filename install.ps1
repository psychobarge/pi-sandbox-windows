# pi-sandbox setup on Windows (Docker Desktop). Run from PowerShell.
# Usage: .\install.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

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

# ====== Extensions to install ======
$EXTENSIONS = @(
  'git:github.com/DietrichGebert/ponytail'
  'npm:pi-web-access'
  'npm:@narumitw/pi-plan-mode'
  'npm:pi-ask-mode'
  'npm:pi-llama-cpp'
)

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
Write-Host '→ Building pi-sandbox image (Node 24 + latest pi)…'
docker build -t pi-sandbox -f Dockerfile.pi .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host '✓ Image ready'

# ====== 2b. rtk data volume (persists `rtk gain` history across launches) ======
docker volume create rtk-data | Out-Null
Write-Host '✓ rtk-data volume ready'

# ====== 3. Model & thinking config (settings.json) ======
Write-Host '→ Installing model config (no default provider, pi asks on first run)…'
docker run --rm -v 'pi-agent-home:/root/.pi/agent' -v (Q "$PSScriptRoot\config:/config:ro") --entrypoint bash pi-sandbox -c 'mkdir -p /root/.pi/agent && cp -f /config/settings.json /root/.pi/agent/ && echo "✓ Model config installed"'

# ====== 4. Extensions (into the persistent pi-agent-home volume) ======
Write-Host '→ Installing extensions…'
foreach ($ext in $EXTENSIONS) {
  Write-Host "   • $ext"
  docker run --rm -v 'pi-agent-home:/root/.pi/agent' pi-sandbox install $ext
}
Write-Host '✓ Extensions installed'

# ====== 5. rtk hook (global pi extension, into the persistent volume) ======
Write-Host '→ Installing rtk pi extension (compresses bash output for the agent)…'
docker run --rm -e RTK_TELEMETRY_DISABLED=1 -v 'pi-agent-home:/root/.pi/agent' --entrypoint bash pi-sandbox -c 'rtk init -g --agent pi'
Write-Host '✓ rtk extension installed'

# ====== 6. DeepSeek opt-in (default: off) ======
Write-Host ''
Write-Host 'DeepSeek is NOT installed by default.'
$want = Read-Host 'Add DeepSeek support (pi-deepseek-peak extension + deepseek model defaults + DEEPSEEK_API_KEY forwarding)? [y/N]'
if ($want -match '^[yY]') {
  Write-Host '→ Installing pi-deepseek-peak…'
  docker run --rm -v 'pi-agent-home:/root/.pi/agent' pi-sandbox install 'git:github.com/psychobarge/pi-deepseek-peak'
  Write-Host '→ Installing deepseek model config…'
  docker run --rm -v 'pi-agent-home:/root/.pi/agent' -v (Q "$PSScriptRoot\config:/config:ro") --entrypoint bash pi-sandbox -c 'cp -f /config/settings.deepseek.json /root/.pi/agent/settings.json && echo "✓ DeepSeek model config installed"'
  $cfg = Get-Content -Raw -LiteralPath .\pi.config.ps1
  if ($cfg -notmatch 'DEEPSEEK_API_KEY') {
    $cfg = $cfg.Replace('"OPENAI_API_KEY"', "`"OPENAI_API_KEY`"`r`n  `"DEEPSEEK_API_KEY`"")
    Set-Content -LiteralPath .\pi.config.ps1 -Value $cfg -Encoding UTF8 -NoNewline
    Write-Host '✓ DEEPSEEK_API_KEY added to API_KEYS (pi.config.ps1)'
  }
  $deepseek = $true
}

# ====== 7. API keys (all optional) ======
Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════'
Write-Host '  API KEYS — set them with:  setx NAME "value"'
Write-Host '  (or add to your PowerShell profile: $PROFILE)'
Write-Host '════════════════════════════════════════════════════════════════'
if ($deepseek) {
  Write-Host 'DeepSeek (required to use the deepseek model):'
  Write-Host ''
  Write-Host '  setx DEEPSEEK_API_KEY "sk-…"'
  Write-Host ''
}
Write-Host 'Tavily (optional — web search for pi-web-access):'
Write-Host ''
Write-Host '  setx TAVILY_API_KEY "tvly-…"'
Write-Host ''
Write-Host 'Then open a NEW terminal (setx does not affect the current one).'
Write-Host '════════════════════════════════════════════════════════════════'

# ====== 8. Launcher in PATH ======
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

# ====== 8b. Git Bash launcher (`pi` bare command in Git Bash too) ======
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
Get-ChildItem logs -Filter '*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
