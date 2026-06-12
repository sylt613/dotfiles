#!/bin/bash
# Auto-start Claude Code in a DETACHED tmux session so the TUI keeps running
# even after you close the browser/VS Code — reattach any time with:
#
#     claude-tui                 # (helper installed by install.sh)
#     tmux attach -t claude      # the raw command it runs
#
# Why tmux: a codespace keeps running while it's awake, but the Claude TUI you
# were talking to dies the moment its terminal closes. Running it inside a
# detached tmux session decouples the long task from your connection — you can
# kick off work, close the laptop, and find it still going (and the smart
# keep-alive in cs_keepalive.sh keeps the machine awake *while Claude is busy*).
#
# Contract: idempotent + best-effort. A no-op when the session already exists,
# and it NEVER fails its caller (always exit 0). Launched by install.sh at
# creation and re-created by session-init.sh after a stop/start (the in-memory
# tmux server dies with the container). The session runs Claude in full-auto
# (--permission-mode bypassPermissions); when Claude exits it drops to a shell
# so the session — and your scrollback — survive, ready to relaunch.

SESSION="${CLAUDE_TMUX_SESSION:-claude}"
STATE_DIR="$HOME/.dotfiles-state"
mkdir -p "$STATE_DIR"

# ── tmux is required; install best-effort if the image doesn't ship it ───────
# (GitHub's universal image has tmux; minimal base images may not. Try once.)
if ! command -v tmux >/dev/null 2>&1 && [ ! -f "$STATE_DIR/tmux-install-tried" ]; then
    touch "$STATE_DIR/tmux-install-tried"
    if command -v apt-get >/dev/null 2>&1; then
        sudo -n apt-get update -qq  >/dev/null 2>&1 \
            && sudo -n apt-get install -y -qq tmux >/dev/null 2>&1
    fi
fi
if ! command -v tmux >/dev/null 2>&1; then
    echo "  ▫️ tmux not available (could not install) — persistent Claude session skipped"
    exit 0
fi

# ── sensible tmux defaults for the Claude TUI (append-only, never clobber) ────
# focus-events: Claude's TUI asks for this; mouse: natural wheel-scroll through
# Claude's output; big history: keep long task scrollback. Added once, at the
# end of any existing ~/.tmux.conf (later settings win), so user config is kept.
if ! grep -q '# >>> ai-dotfiles >>>' "$HOME/.tmux.conf" 2>/dev/null; then
    cat >> "$HOME/.tmux.conf" <<'TMUXCONF'
# >>> ai-dotfiles >>>
set -g focus-events on
set -g mouse on
set -g history-limit 50000
# <<< ai-dotfiles <<<
TMUXCONF
fi

# ── need the claude CLI (the extension ships its own copy, but the tmux TUI
#    needs the standalone CLI) ───────────────────────────────────────────────
CLAUDE_BIN="$(command -v claude 2>/dev/null)"
if [ -z "$CLAUDE_BIN" ]; then
    echo "  ▫️ claude CLI not found — tmux session skipped (VS Code extension still works)"
    exit 0
fi

# ── already running? no-op ───────────────────────────────────────────────────
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "  ✅ tmux session '$SESSION' already running (attach: claude-tui)"
    exit 0
fi

# ── pick the working dir: the user's project, NOT the dotfiles checkout ───────
WORKDIR=""
if [ -n "${CODESPACE_VSCODE_FOLDER:-}" ] && [ -d "${CODESPACE_VSCODE_FOLDER:-}" ]; then
    WORKDIR="$CODESPACE_VSCODE_FOLDER"
elif [ -n "${GITHUB_REPOSITORY:-}" ] && [ -d "/workspaces/${GITHUB_REPOSITORY##*/}" ]; then
    WORKDIR="/workspaces/${GITHUB_REPOSITORY##*/}"
else
    for d in /workspaces/*/; do
        case "$d" in */.codespaces/) continue ;; esac
        [ -d "$d" ] && { WORKDIR="${d%/}"; break; }
    done
fi
[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || WORKDIR="$HOME"

# ── pre-trust the workspace so Claude opens straight to its prompt ───────────
# Claude's folder-trust dialog ("Is this a project you trust?") is a SEPARATE
# gate from permission mode — without this the detached pane would sit on it
# forever. Merge-only and never clobber an unparseable file (same contract as
# install.sh's ~/.claude.json handling — never wipe Claude's live state).
CLAUDE_TRUST_DIR="$WORKDIR" python3 <<'PY' 2>/dev/null || true
import json, os, sys
p = os.path.expanduser("~/.claude.json")
d = os.environ["CLAUDE_TRUST_DIR"]
try:
    cfg = json.load(open(p)) if os.path.exists(p) else {}
except Exception:
    if os.path.exists(p) and os.path.getsize(p) > 2:
        sys.exit(3)   # hand-edited / mid-write — leave it untouched
    cfg = {}
entry = cfg.setdefault("projects", {}).setdefault(d, {})
entry["hasTrustDialogAccepted"] = True
entry.setdefault("allowedTools", [])
tmp = p + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY

# ── start it: Claude in full-auto. We pass the MODE (--permission-mode
#    bypassPermissions) rather than the --dangerously-skip-permissions FLAG:
#    the flag re-shows a warning whose DEFAULT is "No, exit", so a stray
#    keystroke into the unattended pane would kill the session; --permission-mode
#    goes straight to the prompt (and still works even if settings.json somehow
#    lost defaultMode). Falls back to an interactive shell on exit so the
#    session — and your scrollback — survive, ready to relaunch. ───────────────
if tmux new-session -d -s "$SESSION" -c "$WORKDIR" \
        "$CLAUDE_BIN --permission-mode bypassPermissions; exec bash -i" 2>/dev/null; then
    echo "  ✅ Claude Code started in tmux session '$SESSION' (cwd: $WORKDIR, full-auto) — attach: claude-tui"
else
    echo "  ⚠️ could not start tmux session '$SESSION'"
fi
exit 0
