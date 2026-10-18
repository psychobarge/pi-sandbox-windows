# Shared helpers for pi.ps1, install.ps1 and update-pi-sandbox.ps1.
# Dot-sourced (not a module) so nothing leaks into the caller's session when a
# script is run with .\pi.ps1 from an open shell. Tested by tests\pi-sandbox.Tests.ps1.

if (-not ('PiSandbox.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace PiSandbox {
  public static class Native {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder buf, uint len, uint flags);

    // Real path of an existing file/folder: resolves junctions, symlinks, 8.3
    // short names and subst drives in one go. null when it cannot be opened.
    public static string FinalPath(string path) {
      // access 0 + FILE_FLAG_BACKUP_SEMANTICS (0x02000000): folders can be opened
      using (SafeFileHandle h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
        if (h.IsInvalid) return null;
        StringBuilder sb = new StringBuilder(32768);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        return (n == 0 || n >= sb.Capacity) ? null : sb.ToString();
      }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
      public uint Flags; public uint Type; public string TargetName; public string Comment;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
      public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
      public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref CREDENTIAL cred, uint flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);

    // Generic credential (type 1); null when absent.
    public static string CredRead(string target) {
      IntPtr p;
      if (!CredReadW(target, 1, 0, out p)) return null;
      try {
        CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
        return c.CredentialBlobSize == 0 ? null : Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
      } finally { CredFree(p); }
    }

    // SecureString in, so the secret never becomes a managed string here.
    public static void CredWrite(string target, string user, SecureString secret) {
      CREDENTIAL c = new CREDENTIAL();
      c.Type = 1; c.TargetName = target; c.UserName = user;
      c.Persist = 2; // CRED_PERSIST_LOCAL_MACHINE: survives logoff, never roams
      c.CredentialBlobSize = (uint)(secret.Length * 2);
      c.CredentialBlob = Marshal.SecureStringToCoTaskMemUnicode(secret);
      try {
        if (!CredWriteW(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
      } finally { Marshal.ZeroFreeCoTaskMemUnicode(c.CredentialBlob); }
    }
  }
}
'@
}

$PI_CRED_PREFIX = 'pi-sandbox:'
# Keys with a keyproxy route (proxy/keyproxy.mjs): the real value goes to the sidecar only.
$PI_PROXY_ROUTES = @('DEEPSEEK_API_KEY', 'OPENAI_API_KEY', 'TAVILY_API_KEY')

# PS 5.1 native-arg quoting: args containing spaces must carry embedded quotes.
# The scripts set $PSNativeCommandArgumentPassing = 'Legacy' so PS 7.3+ behaves the same.
function Q([string]$a) { if ($a -match ' ') { return '"' + $a + '"' } else { return $a } }

# docker with stderr dropped: under PS 5.1 + $ErrorActionPreference='Stop',
# any native stderr line throws, even with 2>$null.
function Invoke-DockerQuiet {
  $ErrorActionPreference = 'Continue'
  & docker @args 2>$null
}

function Test-Docker {
  $out = Invoke-DockerQuiet version --format '{{.Server.Version}}' | Out-String
  return ($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace($out)
}

# Creates pi.config.ps1 from the example on a fresh clone; returns its path.
function Initialize-Config([string]$Dir) {
  $cfg = Join-Path $Dir 'pi.config.ps1'
  if (-not (Test-Path -LiteralPath $cfg)) {
    Copy-Item -LiteralPath (Join-Path $Dir 'pi.config.example.ps1') -Destination $cfg
    Write-Host '✓ pi.config.ps1 created from pi.config.example.ps1 — edit it to set your folders'
  }
  return $cfg
}

# ====== Paths ======

# Real path, case as on disk, no trailing '\' ("E:\" -> "E:").
function Get-CanonicalPath([string]$Path) {
  $p = [IO.Path]::GetFullPath($Path)
  $final = [PiSandbox.Native]::FinalPath($p)
  if ($final) {
    if ($final.StartsWith('\\?\UNC\')) { $p = '\\' + $final.Substring(8) }
    elseif ($final.StartsWith('\\?\')) { $p = $final.Substring(4) }
    else { $p = $final }
  }
  return $p.TrimEnd('\')
}

# "~\x" -> "$HOME\x", then canonical.
function Resolve-AllowedEntry([string]$Entry) {
  $e = $Entry.Trim()
  if ($e -match '^~(?=[\\/]|$)') { $e = $HOME + $e.Substring(1) }
  return Get-CanonicalPath $e
}

# Only "X:\..." can be mounted and turned into /x/... (UNC, \\wsl$\ cannot).
function Test-DriveLetterPath([string]$Path) { return $Path -match '^[A-Za-z]:(\\|$)' }

function Test-PathInside([string]$Path, [string]$Dir) {
  $ic = [StringComparison]::OrdinalIgnoreCase
  $Path = $Path.TrimEnd('\'); $Dir = $Dir.TrimEnd('\')
  return $Path.Equals($Dir, $ic) -or $Path.StartsWith($Dir + '\', $ic)
}

# a is b, is inside b, or contains b
function Test-PathOverlap([string]$A, [string]$B) { return (Test-PathInside $A $B) -or (Test-PathInside $B $A) }

# Folders whose content runs on the host: mounting them (or a parent) lets the
# agent escape. The repo (pi.ps1, pi.config.ps1, .git hooks), the launchers,
# PowerShell 5.1/7 profiles (OneDrive-redirected Documents included) and Startup.
function Get-ProtectedPaths([string]$RepoDir) {
  $docs = [Environment]::GetFolderPath('MyDocuments')
  $list = @($RepoDir, (Join-Path $HOME '.pi\bin'), [Environment]::GetFolderPath('Startup'))
  if ($docs) { $list += (Join-Path $docs 'WindowsPowerShell'), (Join-Path $docs 'PowerShell') }
  return @($list | Where-Object { $_ } | ForEach-Object { Get-CanonicalPath $_ })
}

function Test-Protected([string]$Dir, [string[]]$Protected) {
  foreach ($p in $Protected) { if (Test-PathOverlap $Dir $p) { return $true } }
  return $false
}

# E:\foo -> /e/foo (container path, so pi's footer shows the real location)
function ConvertTo-ContainerPath([string]$p) {
  return ('/' + $p.Substring(0, 1).ToLowerInvariant() + $p.Substring(2)).Replace('\', '/')
}

# api, api-2, api-3: Docker silently keeps one of two mounts on the same target.
function Get-UniqueName([string]$Name, [System.Collections.Generic.List[string]]$Used) {
  $n = 1; $candidate = $Name
  while ($Used -contains $candidate) { $n++; $candidate = "$Name-$n" }
  $Used.Add($candidate)
  return $candidate
}

# pi.config.ps1 is dot-sourced on the host: the path goes in single quotes,
# escaped for ' and the typographic quotes PowerShell also treats as quotes.
function Format-AllowedLine([string]$Dir) {
  $esc = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Dir)
  return "`$ALLOWED += @('$esc')   # added by pi.ps1"
}

# Appended at the end: works whatever the layout of the $ALLOWED list.
function Add-AllowedFolder([string]$ConfigPath, [string]$Dir, [string[]]$Existing) {
  foreach ($e in $Existing) { if ((Resolve-AllowedEntry $e).Equals($Dir, [StringComparison]::OrdinalIgnoreCase)) { return } }
  [IO.File]::AppendAllText($ConfigPath, "`r`n$(Format-AllowedLine $Dir)`r`n", (New-Object Text.UTF8Encoding $false))
}

# ====== API keys ======

function Read-StoredKey([string]$Name) { return [PiSandbox.Native]::CredRead($PI_CRED_PREFIX + $Name) }
function Write-StoredKey([string]$Name, [Security.SecureString]$Secret) { [PiSandbox.Native]::CredWrite($PI_CRED_PREFIX + $Name, $Name, $Secret) }

# Process env var (one-off override) wins, else Credential Manager. Values are
# put in this process's env and docker gets `-e NAME` only: never in argv.
# Returns the docker args for pi and the sidecar, and the names to remove from
# $env: on exit (only those this function set: a user override is left alone).
function Resolve-ApiKeys([string[]]$Names) {
  $r = @{ EnvArgs = @(); ProxyEnv = @(); Proxied = $false; Set = @() }
  foreach ($k in $Names) {
    if ([Environment]::GetEnvironmentVariable($k, 'User') -or [Environment]::GetEnvironmentVariable($k, 'Machine')) {
      Write-Host "⚠ $k is still a Windows env var (setx): every new process inherits it and it overrides Credential Manager."
      Write-Host "   Remove it: [Environment]::SetEnvironmentVariable('$k', `$null, 'User')"
    }
    $v = [Environment]::GetEnvironmentVariable($k, 'Process')
    if (-not $v) {
      $v = Read-StoredKey $k
      if ($v) { Set-Item -LiteralPath "Env:$k" -Value $v; $r.Set += $k }
    }
    if (-not $v) { continue }
    if ($PI_PROXY_ROUTES -contains $k) {
      $r.ProxyEnv += '-e', $k
      $r.EnvArgs += '-e', "$k=proxy"
      $r.Proxied = $true
      # pi-web-access reads TAVILY_BASE_URL
      if ($k -eq 'TAVILY_API_KEY') { $r.EnvArgs += '-e', 'TAVILY_BASE_URL=http://keyproxy:8787/tavily' }
    } else {
      Write-Host "⚠ $k has no proxy route, exposed to the agent"
      $r.EnvArgs += '-e', $k
    }
  }
  return $r
}

function Test-NetworkArg([string[]]$DockerArgs) {
  foreach ($a in $DockerArgs) { if ($a -match '^--net(work)?(=|$)') { return $true } }
  return $false
}

# ====== keyproxy sidecar ownership ======
# PID + start time: Windows reuses PIDs quickly, a PID alone could keep an
# orphan sidecar (holding the real keys) alive forever.
function Get-OwnerTag { return "$PID-$((Get-Process -Id $PID).StartTime.ToFileTimeUtc())" }

function Test-OwnerAlive([string]$Owner) {
  if ($Owner -notmatch '^(\d+)-(\d+)$') { return $false }
  $p = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
  if (-not $p) { return $false }
  try { return "$($p.StartTime.ToFileTimeUtc())" -eq $Matches[2] } catch { return $false }
}

# A closed window skips `finally`: drop sidecars/networks of dead sessions.
function Remove-OrphanSidecars {
  foreach ($n in @(Invoke-DockerQuiet ps -a --filter label=pi-sandbox.owner --format '{{.Names}}')) {
    if ($n -match '^pi-keyproxy-(.+)$' -and -not (Test-OwnerAlive $Matches[1])) { Invoke-DockerQuiet rm -f $n | Out-Null }
  }
  foreach ($n in @(Invoke-DockerQuiet network ls --filter label=pi-sandbox.owner --format '{{.Name}}')) {
    if ($n -match '^pi-net-(.+)$' -and -not (Test-OwnerAlive $Matches[1])) { Invoke-DockerQuiet network rm $n | Out-Null }
  }
}

# ====== Updater ======

function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path) }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false)) }

# Pins in Dockerfile.pi; empty/null arguments leave that pin alone.
function Update-DockerfilePins([string]$Text, [string]$Pi, [string]$Rtk, [string]$ShaX86, [string]$ShaArm) {
  if ($Pi) { $Text = $Text -replace '@earendil-works/pi-coding-agent@[0-9][0-9.]*', "@earendil-works/pi-coding-agent@$Pi" }
  if ($Rtk) {
    $Text = $Text -replace '(?m)^ARG RTK_VERSION=v.*$', "ARG RTK_VERSION=v$Rtk"
    $Text = $Text -replace '(?m)^ARG RTK_SHA256_X86_64=.*$', "ARG RTK_SHA256_X86_64=$ShaX86"
    $Text = $Text -replace '(?m)^ARG RTK_SHA256_AARCH64=.*$', "ARG RTK_SHA256_AARCH64=$ShaArm"
  }
  return $Text
}

# checksums.txt lines: "<sha256>  <file>"
function Get-RtkHashes([string]$Checksums) {
  $h = @{}
  foreach ($line in ($Checksums -split "`r?`n")) {
    $f = -split $line
    if ($f.Count -eq 2 -and $f[0] -match '^[0-9a-f]{64}$') { $h[$f[1]] = $f[0] }
  }
  return @{
    X86 = $h['rtk-x86_64-unknown-linux-musl.tar.gz']
    Arm = $h['rtk-aarch64-unknown-linux-gnu.tar.gz']
  }
}

# Lock is live only if its PID still runs and really is the updater: a killed
# updater (reboot, kill) must not disable auto-update forever.
function Test-LockLive([string]$Lock) {
  $pidFile = Join-Path $Lock 'pid'
  if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
  $owner = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ("$owner" -notmatch '^\d+$') { return $false }
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue
  return [bool]($p -and $p.CommandLine -like '*update-pi-sandbox*')
}

# $true when acquired. Atomic: New-Item on an existing folder fails.
function Enter-UpdateLock([string]$Lock) {
  if (Test-LockLive $Lock) { return $false }
  if (Test-Path -LiteralPath $Lock) { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue }
  try { New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null } catch { return $false }
  Set-Content -LiteralPath (Join-Path $Lock 'pid') -Value $PID
  return $true
}
