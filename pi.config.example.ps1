# ====== pi-sandbox configuration example ======
# THIS FILE IS A TEMPLATE. pi.ps1 / install.ps1 copy it to `pi.config.ps1`
# (gitignored) on first run — edit that copy, never commit your real config.

# Allowed folders: the container sees ONLY these. Windows paths (E:\...).
# Never list pi-sandbox-windows itself, a folder inside it, or a parent of it
# (E:\, your user profile): the agent could rewrite pi.ps1 / pi.config.ps1 and
# get them run on the host. pi.ps1 skips such entries.
# - Launched from inside one -> confined to that folder, mounted at its real
#   path in the container (/e/... for E:\, /c/... for C:\ — pi's footer shows it).
# - Launched elsewhere and answering "n" -> all mounted under /workspace/<name>.
$ALLOWED = @(
  # "C:\Users\<you>\projects\my-project"
)

# API keys forwarded to the container. Resolved in this order: variable set in
# the current PowerShell process (one-off override), else Windows Credential
# Manager (target "pi-sandbox:<NAME>", stored by install.ps1).
# DEEPSEEK/OPENAI/TAVILY go through the keyproxy sidecar: the container only
# sees the value "proxy". Any OTHER key here has no route and is handed to pi
# as a real env var, readable by the agent.
$API_KEYS = @(
  "TAVILY_API_KEY"
  "OPENAI_API_KEY"
)

# Image and volume (volume = sessions/config/extensions, persists across launches)
$IMAGE = "pi-sandbox"
$VOLUME = "pi-agent-home"
# rtk data (history / `rtk gain` stats) — named volume, same isolation as $VOLUME
$RTK_VOLUME = "rtk-data"
# Container-side mount point for the NON-confined fallback only
# (confined launches mount the folder at its real path).
$WORKSPACE = "/workspace"

# Extra docker arguments.
# No --network/--net here: the launcher needs one for the keyproxy sidecar and
# refuses to start when it finds one (all your keys would be exposed otherwise).
# PI_SKIP_VERSION_CHECK: updates are owned by update-pi-sandbox.ps1 on the host.
# Not a secret, so llama.cpp's URL goes here rather than in $API_KEYS, e.g.
#   "-e", "LLAMA_SERVER_URL=http://host.docker.internal:8083"
$DOCKER_ARGS = @("-e", "PI_SKIP_VERSION_CHECK=1")
