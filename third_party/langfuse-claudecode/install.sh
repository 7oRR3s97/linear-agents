#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/douinc/langfuse-claudecode/main"

# Global install location
GLOBAL_HOOK_DIR="${HOME}/.claude/hooks/langfuse-claudecode"
GLOBAL_HOOK_PATH="${GLOBAL_HOOK_DIR}/langfuse_hook.py"
GLOBAL_SETTINGS="${HOME}/.claude/settings.json"

# Project-level (credentials only)
SETTINGS_LOCAL_FILE=".claude/settings.local.json"
GITIGNORE_FILE=".gitignore"

# Hook command uses fully-expanded $HOME (no tilde in JSON)
HOOK_COMMAND="uv run --project ${GLOBAL_HOOK_DIR} ${GLOBAL_HOOK_PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${BLUE}%s${NC}\n" "$*"; }
ok()    { printf "${GREEN}%s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}%s${NC}\n" "$*"; }
err()   { printf "${RED}%s${NC}\n" "$*" >&2; }

# ── Parse flags ───────────────────────────────────────────────────────

SETUP_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --setup|--setup-only) SETUP_ONLY=true ;;
    esac
done

# ── Preflight ─────────────────────────────────────────────────────────

if ! command -v uv &> /dev/null; then
    err "Error: 'uv' is not installed."
    echo "Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

if command -v curl &> /dev/null; then
    download() { curl -fsSL "$1"; }
elif command -v wget &> /dev/null; then
    download() { wget -qO- "$1"; }
else
    err "Error: neither 'curl' nor 'wget' found."
    exit 1
fi

IN_PROJECT=true
if [ ! -d ".git" ] && [ ! -d ".claude" ]; then
    if [ "$SETUP_ONLY" = true ]; then
        warn "Warning: not in a git repository root."
        echo "Run --setup from your project root directory to configure credentials."
        read -rp "Continue anyway? [y/N] " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        IN_PROJECT=false
        warn "Note: not in a git repository root."
        echo "  Global hook will be installed, but project credentials will be skipped."
        echo "  Run 'curl -fsSL .../install.sh | bash -s -- --setup' from a project root later."
        echo ""
    fi
fi

echo ""
printf "${BOLD}langfuse-claudecode installer${NC}\n"
echo "https://github.com/douinc/langfuse-claudecode"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    info "Mode: --setup (project credentials only)"
    echo ""
fi

# ── Download hook files to global location (skip if --setup) ──────────

if [ "$SETUP_ONLY" = false ]; then
    info "Downloading hook files to ${GLOBAL_HOOK_DIR} ..."
    mkdir -p "${GLOBAL_HOOK_DIR}"

    download "${REPO_RAW}/langfuse_hook.py" > "${GLOBAL_HOOK_PATH}"
    chmod +x "${GLOBAL_HOOK_PATH}"
    ok "  -> langfuse_hook.py"

    download "${REPO_RAW}/pyproject.toml" > "${GLOBAL_HOOK_DIR}/pyproject.toml"
    ok "  -> pyproject.toml"

    download "${REPO_RAW}/uv.lock" > "${GLOBAL_HOOK_DIR}/uv.lock"
    ok "  -> uv.lock"

    echo ""
    info "Installing dependencies (uv sync) ..."
    uv sync --project "${GLOBAL_HOOK_DIR}" --python 3.13
    ok "  -> .venv ready"
fi

# ── Register hook in ~/.claude/settings.json (skip if --setup) ────────

if [ "$SETUP_ONLY" = false ]; then
    echo ""
    info "Configuring ${GLOBAL_SETTINGS} ..."

    mkdir -p "$(dirname "${GLOBAL_SETTINGS}")"

    uv run --no-project --python 3.13 - "${GLOBAL_SETTINGS}" "${HOOK_COMMAND}" << 'PYEOF'
import json, sys, os

file_path = sys.argv[1]
hook_command = sys.argv[2]

if os.path.exists(file_path):
    with open(file_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

settings.setdefault("hooks", {})
settings["hooks"].setdefault("Stop", [])

new_entry = {"hooks": [{"type": "command", "command": hook_command}]}

# Check for existing langfuse hook to avoid duplicates
found = False
for group in settings["hooks"]["Stop"]:
    for h in group.get("hooks", []):
        if "langfuse_hook" in h.get("command", ""):
            h["command"] = hook_command
            found = True
            break

if not found:
    settings["hooks"]["Stop"].append(new_entry)

with open(file_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

    ok "  -> Stop hook registered (user-wide)"
fi

# ── Migrate old project-level installation (skip if --setup) ──────────

if [ "$SETUP_ONLY" = false ] && [ -f ".claude/hooks/langfuse_hook.py" ]; then
    echo ""
    warn "Found old project-level hook at .claude/hooks/langfuse_hook.py"
    read -rp "  Remove old project-level hook file? [Y/n] " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        rm -f ".claude/hooks/langfuse_hook.py"
        ok "  -> Removed .claude/hooks/langfuse_hook.py"
    fi

    # Remove langfuse hook entry from project-level .claude/settings.json
    if [ -f ".claude/settings.json" ]; then
        uv run --no-project --python 3.13 - ".claude/settings.json" << 'PYEOF'
import json, sys, os

file_path = sys.argv[1]

if not os.path.exists(file_path):
    sys.exit(0)

with open(file_path, "r") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
stop_list = hooks.get("Stop", [])

# Filter out groups containing langfuse_hook
new_stop = []
for group in stop_list:
    new_hooks = [h for h in group.get("hooks", []) if "langfuse_hook" not in h.get("command", "")]
    if new_hooks:
        group["hooks"] = new_hooks
        new_stop.append(group)

if new_stop:
    hooks["Stop"] = new_stop
elif "Stop" in hooks:
    del hooks["Stop"]

# Clean up empty hooks dict
if not hooks:
    settings.pop("hooks", None)

with open(file_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
        ok "  -> Cleaned langfuse hook from project .claude/settings.json"
    fi
fi

# ── Interactive credential prompts (skip if --setup with no project) ──

if [ "$SETUP_ONLY" = true ] || [ "$IN_PROJECT" = true ]; then
    echo ""
    info "Configure Langfuse credentials"
    echo "  (stored in ${SETTINGS_LOCAL_FILE}, which will be gitignored)"
    echo ""

    # Support non-interactive mode: skip prompts for pre-set env vars
    if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ]; then
        read -rp "  LANGFUSE_PUBLIC_KEY (pk-lf-...): " LANGFUSE_PUBLIC_KEY < /dev/tty
    fi
    if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ]; then
        err "Error: LANGFUSE_PUBLIC_KEY is required."
        exit 1
    fi

    if [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
        read -rp "  LANGFUSE_SECRET_KEY (sk-lf-...): " LANGFUSE_SECRET_KEY < /dev/tty
    fi
    if [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
        err "Error: LANGFUSE_SECRET_KEY is required."
        exit 1
    fi

    if [ -z "${LANGFUSE_BASE_URL:-}" ]; then
        read -rp "  LANGFUSE_BASE_URL [https://cloud.langfuse.com]: " LANGFUSE_BASE_URL < /dev/tty
    fi
    LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"

    if [ -z "${CC_LANGFUSE_USER_ID:-}" ]; then
        read -rp "  CC_LANGFUSE_USER_ID (e.g. your email, optional): " CC_LANGFUSE_USER_ID < /dev/tty
    fi

    if [ -z "${CC_LANGFUSE_ENVIRONMENT:-}" ]; then
        read -rp "  CC_LANGFUSE_ENVIRONMENT (e.g. project name, optional): " CC_LANGFUSE_ENVIRONMENT < /dev/tty
    fi

    # ── Merge .claude/settings.local.json ─────────────────────────────

    info "Configuring ${SETTINGS_LOCAL_FILE} ..."
    mkdir -p "$(dirname "${SETTINGS_LOCAL_FILE}")"

    _INSTALL_USER_ID="${CC_LANGFUSE_USER_ID:-}" \
    _INSTALL_ENVIRONMENT="${CC_LANGFUSE_ENVIRONMENT:-}" \
    _INSTALL_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY}" \
    _INSTALL_SECRET_KEY="${LANGFUSE_SECRET_KEY}" \
    _INSTALL_BASE_URL="${LANGFUSE_BASE_URL}" \
    uv run --no-project --python 3.13 - "${SETTINGS_LOCAL_FILE}" << 'PYEOF'
import json, sys, os

file_path = sys.argv[1]

if os.path.exists(file_path):
    with open(file_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

settings.setdefault("env", {})

settings["env"]["TRACE_TO_LANGFUSE"] = "true"
settings["env"]["LANGFUSE_PUBLIC_KEY"] = os.environ["_INSTALL_PUBLIC_KEY"]
settings["env"]["LANGFUSE_SECRET_KEY"] = os.environ["_INSTALL_SECRET_KEY"]
settings["env"]["LANGFUSE_BASE_URL"] = os.environ["_INSTALL_BASE_URL"]

user_id = os.environ.get("_INSTALL_USER_ID", "")
environment = os.environ.get("_INSTALL_ENVIRONMENT", "")
if user_id:
    settings["env"]["CC_LANGFUSE_USER_ID"] = user_id
if environment:
    settings["env"]["CC_LANGFUSE_ENVIRONMENT"] = environment

with open(file_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

    ok "  -> Credentials saved"

    # ── Update .gitignore ─────────────────────────────────────────────

    if [ ! -f "${GITIGNORE_FILE}" ]; then
        echo ".claude/settings.local.json" > "${GITIGNORE_FILE}"
        ok "  -> Created ${GITIGNORE_FILE}"
    elif ! grep -qxF ".claude/settings.local.json" "${GITIGNORE_FILE}"; then
        printf "\n# Claude Code local settings (contains secrets)\n.claude/settings.local.json\n" >> "${GITIGNORE_FILE}"
        ok "  -> Added to ${GITIGNORE_FILE}"
    else
        ok "  -> ${GITIGNORE_FILE} already up to date"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────

echo ""
printf "${GREEN}${BOLD}Installation complete!${NC}\n"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    echo "  Secrets:  ${SETTINGS_LOCAL_FILE}"
else
    echo "  Hook:     ${GLOBAL_HOOK_PATH}"
    echo "  Settings: ${GLOBAL_SETTINGS}"
    if [ "$IN_PROJECT" = true ]; then
        echo "  Secrets:  ${SETTINGS_LOCAL_FILE}"
    fi
fi
echo ""
echo "Next steps:"
echo "  1. Start Claude Code in this project directory"
echo "  2. Have a conversation - traces will appear in Langfuse"
if [ -n "${LANGFUSE_BASE_URL:-}" ]; then
    echo "  3. View traces at: ${LANGFUSE_BASE_URL}"
fi
echo ""
echo "To add tracing to another project:"
echo "  curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/install.sh | bash -s -- --setup"
echo ""
echo "Troubleshooting:"
echo "  - Logs:  tail -f ~/.claude/state/langfuse_hook.log"
echo "  - Debug: add \"CC_LANGFUSE_DEBUG\": \"true\" to ${SETTINGS_LOCAL_FILE}"
echo "  - Test:  echo '{}' | uv run --project ${GLOBAL_HOOK_DIR} ${GLOBAL_HOOK_PATH}"
echo ""
