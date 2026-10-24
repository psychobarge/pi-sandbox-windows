# pi-sandbox-windows 1.0.0

Run the [pi](https://github.com/earendil-works/pi-mono) coding agent in a
Docker container on Windows, as [Pi-Bolt](https://github.com/opensec-git/Pi-Bolt)
(pi compiled ahead of time to native code: same commands, sessions and
extensions, faster and lighter). The agent sees **only the folders you allow** —
not your user profile, not `~\.ssh`, not your host `~\.pi\agent`, and never
your API keys. It has limits: see
[what the sandbox does not protect](#what-the-sandbox-does-not-protect).

Windows / PowerShell port of [pi-sandbox](https://github.com/psychobarge/pi-sandbox)
(macOS), at the same security level.

## Quick start

Requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) and
PowerShell 5.1 (preinstalled) or 7. In Docker Desktop → *Settings → General*,
keep **"Expose daemon on tcp://localhost:2375 without TLS" off**: on, the
container could drive Docker, and so your PC.

```powershell
cd pi-sandbox-windows
.\install.ps1
```

The installer builds the image, asks for your API keys (stored in Windows
Credential Manager) and installs the `pi` command (cmd, PowerShell and Git
Bash). Open a new terminal, then, from any project:

```powershell
cd E:\my-project
pi
```

The first time, pi asks to add the folder to the allowed list. Answer `y`.
That's it.

## Configuration

Everything lives in `pi.config.ps1` (created from `pi.config.example.ps1`, gitignored):

```powershell
$ALLOWED = @(                 # folders the agent may see
  "E:\my-project"
)
$API_KEYS = @("DEEPSEEK_API_KEY", "OPENAI_API_KEY", "TAVILY_API_KEY")
```

Edit it, quit pi (`Ctrl-D`) and relaunch. Sessions, settings and extensions are
kept across launches. `pi.config.example.ps1` lists every proxied key, commented
out: uncomment the ones you use and re-run `.\install.ps1` to store them.

To add or change a key later, delete it then re-run the installer, which asks
for it with hidden input:

```powershell
cmdkey /delete:pi-sandbox:OPENAI_API_KEY
.\install.ps1
```

Never use `cmdkey /pass:<key>`: the key would land in your shell history.

A key set in your shell (`$env:OPENAI_API_KEY = …`) **overrides Credential
Manager** for that launch. Never store keys with `setx`: they sit in plain text
in the registry and every program you start inherits them. pi warns you if one
is still there. **Use Credential Manager to keep your keys secure.**

## Extensions

Install them from inside a pi session, then reload:

```
!pi install npm:@author/package
/reload
```

Extensions run with the agent's permissions: only install what you trust.
Pi-Bolt interprets extensions (no JIT): light ones don't notice, heavy ones
(search, parsing) run slower than on stock pi.

[pi-llama-cpp](https://pi.dev/packages/pi-llama-cpp) is installed by default:
it reaches a llama.cpp server running on Windows at
`http://host.docker.internal:8083` (`llamaServerUrl` in `config/settings.json`).

## Updates

Automatic. Each launch checks for new Pi-Bolt and rtk releases and rebuilds
the image in the background; relaunch to use it. Inside pi,
`!pi-bolt update --extensions` updates your extensions (kept in the volume);
plain `pi-bolt update` updates Pi-Bolt itself and is lost on exit (the container
is thrown away): leave that to the rebuild. To update right away:

```powershell
.\update-pi-sandbox.ps1
```

### Coming from stock pi

Nothing to do: the first launch sees an image without Pi-Bolt as out of date
and rebuilds it in the background; relaunch once it is done. The
`pi-agent-home` volume (settings, sessions, extensions) is used as is. To check
the install from inside pi: `!pi-bolt doctor`.

To go back to stock pi, check out a commit before the switch, then rebuild:

```powershell
docker build -t pi-sandbox -f Dockerfile.pi .
```

## How it works

- **Isolation** — only the folders in `ALLOWED` are mounted, at their real path
  (`E:\x` appears as `/e/x`). pi's data lives in Docker volumes, never in your
  host `~\.pi`. The repo itself, its parents, the launchers and your PowerShell
  profiles are never mounted.
- **Keys stay outside** — the container only sees the value `proxy`. A small
  sidecar ([`proxy/keyproxy.mjs`](proxy/keyproxy.mjs)) adds the real key to
  requests sent to the provider. The agent can use a key but not read it.
  Proxied keys: `TAVILY_API_KEY` and, for pi's providers, `DEEPSEEK_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`,
  `CEREBRAS_API_KEY`, `XAI_API_KEY`, `MISTRAL_API_KEY`, `TOGETHER_API_KEY`,
  `NVIDIA_API_KEY`, `HF_TOKEN`, `MOONSHOT_API_KEY` (moonshot.ai only),
  `ZAI_API_KEY`, `KIMI_API_KEY`, `MINIMAX_API_KEY`, `BASETEN_API_KEY`,
  `META_API_KEY`, `XIAOMI_API_KEY`, `ANT_LING_API_KEY`,
  `QWEN_TOKEN_PLAN_API_KEY`. OpenRouter, Fireworks, OpenCode and the cloud
  providers (Bedrock, Vertex, Azure, Cloudflare) are not proxied yet.
- **Fewer tokens** — [rtk](https://github.com/rtk-ai/rtk) compresses the output
  of shell commands.
- **Verified downloads** — the Pi-Bolt tarball is checked against the
  release's `SHA256SUMS`, itself checked against its Ed25519 signature (key
  pinned in `Dockerfile.pi`); rtk against pinned SHA-256 hashes.

WSL is not used directly: only Docker Desktop runs its engine there.

## What the sandbox does not protect

- **Files in allowed folders** are readable: `.env`, tokens, credentials. Keep
  secrets out of them.
- **Keys can be spent.** The agent could call any proxied provider, whatever
  model you picked: with a DeepSeek and an OpenAI key, a session on a DeepSeek
  model can still call the OpenAI API. **This is true of pi without the sandbox
  too** (there it can even read the keys). Keep only the keys you use and set a
  spending cap on each.
- **Keys without a proxy route** (anything not in the list above) are passed to the agent as plain env vars. pi warns you at launch.
- **Never use `/login` in pi**: it saves the key where the agent can read it.
- **Pi-Bolt is a third-party build** of pi (by OpenSec), not the official
  package. The signature proves the binary is OpenSec's release, not that it
  does only what pi does. It runs inside the sandbox and never sees your keys.
- **Credential Manager is not a vault**: unlike the macOS Keychain, any program
  running under your account can read a generic credential.
- **Host services** stay reachable through `host.docker.internal` (llama.cpp,
  but also any other local server).
- **Written files can run on your PC**: git hooks, `core.fsmonitor` in
  `.git/config` (run by the `git status` of a posh-git / oh-my-posh prompt as
  soon as you `cd` into the folder), `.vscode/tasks.json`, npm scripts,
  `.ps1` / `.bat`… Review the agent's changes before running anything.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `failed to connect to the docker API` | Start Docker Desktop |
| `⚠ folder not found` | Fix the path in `ALLOWED` |
| `⚠ skipping …` | The folder is the repo, a parent of it, or a profile folder: pick a project folder |
| pi doesn't see a folder | Add it to `ALLOWED`, then relaunch |
| Provider not authenticated | `cmdkey /list` should show `pi-sandbox:<KEY>` |
| `pi` not recognized | Open a new terminal, or re-run `.\install.ps1` |
| `pi-bolt: command not found` inside pi | The image predates Pi-Bolt: run `.\update-pi-sandbox.ps1`, then relaunch |
| An extension is slow to load | Pi-Bolt interprets extensions: `!pi-bolt doctor` shows each one's load time |
