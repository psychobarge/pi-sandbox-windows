# Pester 5+ tests, no Docker or network needed (docker is a PowerShell function here).
#   Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
#   Invoke-Pester .\tests

BeforeAll {
  $Repo = Split-Path -Parent $PSScriptRoot
  . (Join-Path $Repo 'lib\pi-sandbox.ps1')
}

Describe 'protected paths' {
  BeforeAll {
    $root = Get-CanonicalPath (New-Item -ItemType Directory "$TestDrive\work").FullName
    $repo = (New-Item -ItemType Directory "$root\pi-sandbox-wsl").FullName
    New-Item -ItemType Directory "$repo\sub" | Out-Null
    New-Item -ItemType Directory "$root\other" | Out-Null
    $prot = Get-ProtectedPaths $repo
  }
  It 'refuses the repo, a parent and a child' {
    Test-Protected $repo $prot | Should -BeTrue
    Test-Protected $root $prot | Should -BeTrue
    Test-Protected "$repo\sub" $prot | Should -BeTrue
    Test-Protected ($root.Substring(0, 2)) $prot | Should -BeTrue   # drive root
  }
  It 'allows a sibling, even one sharing the name prefix' {
    New-Item -ItemType Directory "$root\pi-sandbox-wsl-2" | Out-Null
    Test-Protected "$root\other" $prot | Should -BeFalse
    Test-Protected "$root\pi-sandbox-wsl-2" $prot | Should -BeFalse
  }
  It 'ignores case' {
    Test-Protected $repo.ToUpperInvariant() $prot | Should -BeTrue
  }
  It 'resolves a junction to the repo' {
    $j = "$root\link"
    New-Item -ItemType Junction -Path $j -Target $repo | Out-Null
    Resolve-AllowedEntry $j | Should -Be $repo
    Test-Protected (Resolve-AllowedEntry $j) $prot | Should -BeTrue
  }
  It 'resolves an 8.3 short name' {
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($repo).ShortPath
    if ($short -eq $repo) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
    Resolve-AllowedEntry $short | Should -Be $repo
  }
  It 'refuses the profile, launcher and user home' {
    Test-Protected (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell') $prot | Should -BeTrue
    Test-Protected (Get-CanonicalPath (Join-Path $HOME '.pi\bin')) $prot | Should -BeTrue
    Test-Protected (Get-CanonicalPath $HOME) $prot | Should -BeTrue
  }
  It 'expands ~ and drops the trailing backslash' {
    Resolve-AllowedEntry '~\' | Should -Be (Get-CanonicalPath $HOME)
  }
  It 'accepts only drive-letter paths' {
    Test-DriveLetterPath 'E:\x' | Should -BeTrue
    Test-DriveLetterPath 'E:' | Should -BeTrue
    Test-DriveLetterPath '\\server\share' | Should -BeFalse
    Test-DriveLetterPath '\\wsl$\Ubuntu' | Should -BeFalse
  }
  It 'matches inside a folder case-insensitively, not by prefix' {
    Test-PathInside 'e:\dev perso\x\y' 'E:\DEV perso\x' | Should -BeTrue
    Test-PathInside 'E:\DEV perso\xy' 'E:\DEV perso\x' | Should -BeFalse
  }
}

Describe 'adding to $ALLOWED' {
  It 'writes <name> as literal text' -ForEach @(
    @{ name = 'apostrophe'; dir = "C:\it's" }
    @{ name = 'typographic quotes'; dir = "C:\x’; throw 'pwned'; ‘" }
    @{ name = 'subexpression'; dir = 'C:\x$(throw "pwned")' }
    @{ name = 'backtick'; dir = 'C:\a`$b' }
  ) {
    $cfg = "$TestDrive\cfg-$name.ps1"
    Set-Content -LiteralPath $cfg -Value '$ALLOWED = @()' -Encoding UTF8
    Add-AllowedFolder $cfg $dir @()
    $ALLOWED = $null
    . $cfg
    $ALLOWED | Should -HaveCount 1
    $ALLOWED[0] | Should -BeExactly $dir
  }
  It 'does not add a folder already listed (any case)' {
    $d = (New-Item -ItemType Directory "$TestDrive\Proj").FullName
    $cfg = "$TestDrive\cfg-dup.ps1"
    Set-Content -LiteralPath $cfg -Value '$ALLOWED = @()' -Encoding UTF8
    Add-AllowedFolder $cfg (Get-CanonicalPath $d) @($d.ToLowerInvariant())
    (Get-Content -LiteralPath $cfg) | Should -HaveCount 1
  }
}

Describe 'mount names' {
  It 'suffixes duplicates' {
    $used = New-Object System.Collections.Generic.List[string]
    (Get-UniqueName 'api' $used), (Get-UniqueName 'api' $used), (Get-UniqueName 'api' $used) | Should -Be @('api', 'api-2', 'api-3')
  }
}

Describe 'API keys' {
  BeforeEach {
    Remove-Item Env:DEEPSEEK_API_KEY, Env:TAVILY_API_KEY, Env:PI_TEST_OTHER_KEY -ErrorAction SilentlyContinue
    Mock Read-StoredKey { "secret-$Name" }
  }
  AfterEach { Remove-Item Env:DEEPSEEK_API_KEY, Env:TAVILY_API_KEY, Env:PI_TEST_OTHER_KEY -ErrorAction SilentlyContinue }

  It 'never puts a value in docker args' {
    $r = Resolve-ApiKeys @('DEEPSEEK_API_KEY', 'TAVILY_API_KEY', 'PI_TEST_OTHER_KEY')
    ($r.EnvArgs + $r.ProxyEnv) -join ' ' | Should -Not -Match 'secret'
    $env:DEEPSEEK_API_KEY | Should -Be 'secret-DEEPSEEK_API_KEY'
  }
  It 'routes proxied keys to the sidecar and gives pi "proxy"' {
    $r = Resolve-ApiKeys @('DEEPSEEK_API_KEY', 'TAVILY_API_KEY')
    $r.Proxied | Should -BeTrue
    $r.ProxyEnv | Should -Be @('-e', 'DEEPSEEK_API_KEY', '-e', 'TAVILY_API_KEY')
    $r.EnvArgs | Should -Contain 'DEEPSEEK_API_KEY=proxy'
    $r.EnvArgs | Should -Contain 'TAVILY_BASE_URL=http://keyproxy:8787/tavily'
  }
  It 'passes keys without a route by name and does not start the proxy' {
    $r = Resolve-ApiKeys @('PI_TEST_OTHER_KEY')
    $r.Proxied | Should -BeFalse
    $r.EnvArgs | Should -Be @('-e', 'PI_TEST_OTHER_KEY')
  }
  It 'prefers a process override and leaves it in place' {
    $env:DEEPSEEK_API_KEY = 'override'
    $r = Resolve-ApiKeys @('DEEPSEEK_API_KEY')
    $r.Set | Should -BeNullOrEmpty
    Should -Invoke Read-StoredKey -Times 0
  }
  It 'reports the keys it set, for cleanup' {
    (Resolve-ApiKeys @('DEEPSEEK_API_KEY', 'PI_TEST_OTHER_KEY')).Set | Should -Be @('DEEPSEEK_API_KEY', 'PI_TEST_OTHER_KEY')
  }
  It 'detects --network in DOCKER_ARGS' {
    Test-NetworkArg @('--network', 'none') | Should -BeTrue
    Test-NetworkArg @('--net=host') | Should -BeTrue
    Test-NetworkArg @('-e', 'PI_SKIP_VERSION_CHECK=1') | Should -BeFalse
  }
}

Describe 'sidecar ownership' {
  It 'knows its own session is alive' { Test-OwnerAlive (Get-OwnerTag) | Should -BeTrue }
  It 'treats a reused PID (other start time) as dead' { Test-OwnerAlive "$PID-1" | Should -BeFalse }
  It 'treats garbage as dead' { Test-OwnerAlive 'x' | Should -BeFalse }
}

Describe 'updater' {
  It 'reclaims a lock whose PID is not an updater' {
    $lock = "$TestDrive\lock1"
    New-Item -ItemType Directory $lock | Out-Null
    Set-Content "$lock\pid" $PID   # alive, but not update-pi-sandbox
    Enter-UpdateLock $lock | Should -BeTrue
    (Get-Content "$lock\pid") | Should -Be "$PID"
  }
  It 'reclaims a lock without pid file' {
    $lock = "$TestDrive\lock2"
    New-Item -ItemType Directory $lock | Out-Null
    Enter-UpdateLock $lock | Should -BeTrue
  }
  It 'keeps a live updater lock' {
    $lock = "$TestDrive\lock3"
    $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30 # update-pi-sandbox'
    try {
      New-Item -ItemType Directory $lock | Out-Null
      Set-Content "$lock\pid" $p.Id
      Enter-UpdateLock $lock | Should -BeFalse
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
  It 'repins pi and rtk, keeping UTF-8 without BOM' {
    $f = "$TestDrive\Dockerfile.pi"
    $src = "# image — test`nARG RTK_VERSION=v1.0.1`nARG RTK_SHA256_X86_64=aaa`nARG RTK_SHA256_AARCH64=bbb`nRUN npm install -g @earendil-works/pi-coding-agent@1.3.0`n"
    Write-Utf8 $f $src
    Write-Utf8 $f (Update-DockerfilePins (Read-Utf8 $f) '1.4.0' '1.0.2' ('c' * 64) ('d' * 64))
    $bytes = [IO.File]::ReadAllBytes($f)
    $bytes[0] | Should -Not -Be 0xEF
    $t = Read-Utf8 $f
    $t | Should -Match '# image — test'
    $t | Should -Match 'pi-coding-agent@1\.4\.0'
    $t | Should -Match "ARG RTK_VERSION=v1\.0\.2`n"
    $t | Should -Match "ARG RTK_SHA256_X86_64=c{64}`n"
    $t | Should -Match "ARG RTK_SHA256_AARCH64=d{64}`n"
  }
  It 'leaves rtk alone when not bumped' {
    Update-DockerfilePins "ARG RTK_VERSION=v1.0.1`n" '1.4.0' $null $null $null | Should -Be "ARG RTK_VERSION=v1.0.1`n"
  }
  It 'parses checksums.txt' {
    $h = Get-RtkHashes ("$('a' * 64)  rtk-x86_64-unknown-linux-musl.tar.gz`r`n$('b' * 64)  rtk-aarch64-unknown-linux-gnu.tar.gz`n$('c' * 64)  other.tar.gz")
    $h.X86 | Should -Be ('a' * 64)
    $h.Arm | Should -Be ('b' * 64)
  }
  It 'pins match the current Dockerfile.pi format' {
    $t = Read-Utf8 (Join-Path $Repo 'Dockerfile.pi')
    $t | Should -Match '(?m)^ARG RTK_SHA256_X86_64=[0-9a-f]{64}\r?$'
    $t | Should -Match 'sha256sum -c'
  }
}

Describe 'pi.ps1 end to end (fake docker)' {
  BeforeAll {
    $copy = (New-Item -ItemType Directory "$TestDrive\repo").FullName
    foreach ($p in 'pi.ps1', 'lib', 'proxy', 'config', 'pi.config.example.ps1') { Copy-Item -Recurse (Join-Path $Repo $p) $copy }
    Set-Content "$copy\update-pi-sandbox.ps1" "Write-Output 'up-to-date'"
    $proj = Get-CanonicalPath (New-Item -ItemType Directory "$TestDrive\proj").FullName
    $cfg = Get-Content -Raw (Join-Path $Repo 'pi.config.example.ps1')
    $cfg += "`r`n`$ALLOWED = @('$proj', '$copy')`r`n`$API_KEYS = @('DEEPSEEK_API_KEY', 'PISANDBOX_TEST_KEY')`r`n"
    Set-Content -LiteralPath "$copy\pi.config.ps1" -Value $cfg -Encoding UTF8
    # stored key without a route (so it reaches pi by name), proxied key as a process override
    $sec = ConvertTo-SecureString 'stored-secret-123' -AsPlainText -Force
    Write-StoredKey 'PISANDBOX_TEST_KEY' $sec
    $env:DEEPSEEK_API_KEY = 'override-secret-456'

    $global:dockerCalls = New-Object System.Collections.Generic.List[string]
    function global:docker {
      $line = $args -join ' '
      $global:dockerCalls.Add($line)
      $global:LASTEXITCODE = 0
      if ($line -match '^version') { return '29.0.0' }
      if ($line -match '^ps ') { return 'pi-keyproxy-1-1' }
      if ($line -match '^logs ') { return 'keyproxy listening' }
      if ($line -match '^run --rm -it') {
        $global:envDuringRun = "$env:PISANDBOX_TEST_KEY"
        $global:LASTEXITCODE = 3
      }
    }
    Push-Location -LiteralPath $proj
    & "$copy\pi.ps1"
    $global:exitCode = $LASTEXITCODE
    Pop-Location
    $calls = $global:dockerCalls -join "`n"
  }
  AfterAll {
    Remove-Item function:global:docker
    Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
    cmdkey /delete:pi-sandbox:PISANDBOX_TEST_KEY | Out-Null
  }

  It 'returns the session exit code' { $global:exitCode | Should -Be 3 }
  It 'never puts a key value on a docker command line' {
    $calls | Should -Not -Match 'stored-secret-123'
    $calls | Should -Not -Match 'override-secret-456'
  }
  It 'gives the key to pi during the session, then removes it' {
    $global:envDuringRun | Should -Be 'stored-secret-123'
    Test-Path Env:PISANDBOX_TEST_KEY | Should -BeFalse
  }
  It 'leaves a user override in place' { $env:DEEPSEEK_API_KEY | Should -Be 'override-secret-456' }
  It 'starts a hardened sidecar without published ports' {
    $side = $global:dockerCalls | Where-Object { $_ -match '^run -d' }
    $side | Should -Match '--read-only --cap-drop ALL --security-opt no-new-privileges --user node'
    $side | Should -Match ' -e DEEPSEEK_API_KEY '
    $side | Should -Not -Match ' -p '
  }
  It 'confines pi and keeps the repo out' {
    $run = $global:dockerCalls | Where-Object { $_ -match '^run --rm -it' }
    $run | Should -Match '-e DEEPSEEK_API_KEY=proxy'
    $run | Should -Match '-e PISANDBOX_TEST_KEY '
    $run | Should -Match '--network pi-net-'
    $run | Should -Match 'models\.json:/root/\.pi/agent/models\.json:ro'
    $run | Should -Not -Match ([regex]::Escape($copy) + ':')
  }
  It 'removes orphan sidecars and its own sidecar/network' {
    $calls | Should -Match '(?m)^rm -f pi-keyproxy-1-1$'
    $calls | Should -Match '(?m)^rm -f pi-keyproxy-\d+-\d+$'
    $calls | Should -Match '(?m)^network rm pi-net-\d+-\d+$'
  }
}
