# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added
- keyproxy routes for 18 more of pi's providers (same `keyproxy.mjs` as
  pi-sandbox): Anthropic, Google Gemini, Groq, Cerebras, xAI, Mistral,
  Together, NVIDIA, Hugging Face, Moonshot, Z.ai, Kimi Coding, MiniMax,
  Baseten, Meta, Xiaomi, Ant Ling and Qwen Token Plan. Each route sends the
  key in the header its provider reads (`Authorization: Bearer`, `x-api-key`
  or `x-goog-api-key`) and drops the others, and `config/models.json` points
  each provider at its route.
- `pi.config.example.ps1` lists every proxied key (commented out).

### Changed
- `lib/pi-sandbox.ps1` reads the proxied key names from `proxy/keyproxy.mjs`,
  so adding a route no longer needs an edit in the launcher.
  `keyproxy.mjs --selftest` fails if `config/models.json` and the routes
  disagree.

## [1.0.0] — 2026-10-18

Initial release: Windows / PowerShell port of
[pi-sandbox](https://github.com/psychobarge/pi-sandbox) 1.1.0 (macOS), at the
same security level.

### Added
- `install.ps1`: checks/starts Docker Desktop, builds the image, seeds
  `settings.json` in the `pi-agent-home` volume (never overwrites an existing
  one, so installed extensions are kept), installs the rtk hook, asks for the
  API keys (hidden input, stored in Windows Credential Manager) and installs the
  `pi` launcher for cmd, PowerShell and Git Bash.
- DeepSeek opt-in: merges the DeepSeek defaults (`deepseek-flash`,
  `pi-deepseek-peak`) into `settings.json` and adds `DEEPSEEK_API_KEY` to
  `$API_KEYS`. Packages installed from git by earlier setups are replaced by
  their npm versions.
- `pi.ps1`: launches pi confined to the allowed folder it is run from (whitelist
  prompt elsewhere, all allowed folders mounted on "n"), with tool caches kept
  in the volume. Missing folders are skipped and same-name folders get a suffix.
- Protected paths: the repo, a folder inside it or containing it, `~\.pi\bin`,
  PowerShell 5.1/7 profiles and the Startup folder are never mounted. Paths are
  resolved (junctions, 8.3 names, `subst`) and compared case-insensitively.
- Folders added to `$ALLOWED` are written as escaped single-quoted strings, so
  a folder name can never run code from the dot-sourced config.
- API keys: read from the current shell (one-off override), else Credential
  Manager. Never on docker's command line, removed from the shell's environment
  on exit, with a warning when a key is still stored with `setx`.
- keyproxy sidecar: DeepSeek, OpenAI and Tavily keys stay in the sidecar, the
  container only sees `proxy`. Private network per session, hardened container
  without published ports, orphans of closed windows removed (owner = PID +
  start time). `config/models.json` is mounted read-only.
- `update-pi-sandbox.ps1`: tracks pi and rtk releases, repins rtk's SHA-256
  hashes from its `checksums.txt`, rebuilds in the background, removes the
  previous image by ID, recovers an orphan lock and keeps `Dockerfile.pi` in UTF-8.
- `Dockerfile.pi`: Node 24 (trixie) with pi, git, ripgrep, Python and rtk
  (download verified by SHA-256).
- Default extensions: ponytail, pi-web-access, pi-plan-mode, pi-ask-mode,
  pi-llama-cpp (llama.cpp on the host via `host.docker.internal`).
- Pester tests (`tests\`) and keyproxy self-test.
