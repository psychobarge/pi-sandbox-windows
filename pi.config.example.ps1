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
# Every key below goes through the keyproxy sidecar: the container only sees
# the value "proxy". Any OTHER key has no route and is handed to pi as a real
# env var, readable by the agent. Keep only the keys you use: the agent can
# spend any of them (see README). Uncomment one, then re-run .\install.ps1 to
# store it in Credential Manager.
$API_KEYS = @(
  "TAVILY_API_KEY"
  "OPENAI_API_KEY"
  # "DEEPSEEK_API_KEY"
  # "ANTHROPIC_API_KEY"
  # "GEMINI_API_KEY"
  # "GROQ_API_KEY"
  # "CEREBRAS_API_KEY"
  # "XAI_API_KEY"
  # "MISTRAL_API_KEY"
  # "TOGETHER_API_KEY"
  # "NVIDIA_API_KEY"
  # "HF_TOKEN"
  # "MOONSHOT_API_KEY"
  # "ZAI_API_KEY"
  # "KIMI_API_KEY"
  # "MINIMAX_API_KEY"
  # "BASETEN_API_KEY"
  # "META_API_KEY"
  # "XIAOMI_API_KEY"
  # "ANT_LING_API_KEY"
  # "QWEN_TOKEN_PLAN_API_KEY"
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
