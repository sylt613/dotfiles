#!/bin/bash
# Codespaces dotfiles bootstrap — Claude Code CLI + VS Code extension,
# auto-login from Codespaces secrets, full-auto permission mode, provider
# config, git/gh wiring, smart keep-alive.
#
# GitHub runs this once when a codespace is CREATED (and again on container
# rebuilds). It must never die halfway: no `set -e`, every step is
# best-effort, everything is logged to ~/.dotfiles-install.log (also visible
# in /workspaces/.codespaces/.persistedshare/creation.log).

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOG_FILE="$HOME/.dotfiles-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 AI Coding Environment Setup — $(date '+%F %T') (dotfiles: $DOTFILES_DIR)"
chmod +x "$DOTFILES_DIR"/*.sh "$DOTFILES_DIR/ai-check" 2>/dev/null
mkdir -p "$HOME/.dotfiles-state" "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# ── Claude Code CLI ──────────────────────────────────────────────────────────
echo "🤖 Claude Code CLI..."
if ! command -v claude >/dev/null 2>&1; then
    # Native installer first (fast, self-updating), npm as fallback.
    timeout 240 bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1
    if ! command -v claude >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        timeout 300 npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
    fi
fi
if command -v claude >/dev/null 2>&1; then
    echo "  ✅ claude installed ($(claude --version 2>/dev/null | head -1))"
else
    echo "  ⚠️ claude CLI install failed (the VS Code extension ships its own copy, so chat still works)"
fi

# ── Auth bootstrap: fetch artifact if no secrets were injected at codespace creation ─
# gh is always pre-authenticated in every codespace (regardless of which repo),
# so we can pull the daily-updated artifact from the private dotfiles repo as a
# fallback when the new repo hasn't been granted the Codespace secrets yet.
if [ -z "${CLAUDE_CREDENTIALS_JSON:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
   && command -v gh >/dev/null 2>&1; then
    echo "🔑 No Claude auth secrets in env — trying artifact bootstrap from dotfiles repo..."
    _ARTDIR=$(mktemp -d)
    _LATEST=$(gh run list --repo sylt613/dotfiles --workflow grant-secrets.yml \
        --status success --json databaseId --jq '.[0].databaseId' 2>/dev/null)
    if [ -n "$_LATEST" ] && \
       gh run download "$_LATEST" -n cs-auth --repo sylt613/dotfiles \
           --dir "$_ARTDIR" 2>/dev/null; then
        if [ -f "$_ARTDIR/creds_b64.txt" ]; then
            export CLAUDE_CREDENTIALS_JSON=$(cat "$_ARTDIR/creds_b64.txt")
            echo "  ✅ Bootstrapped CLAUDE_CREDENTIALS_JSON from artifact (run $_LATEST)"
        fi
        if [ -f "$_ARTDIR/oauth_token.txt" ]; then
            export CLAUDE_CODE_OAUTH_TOKEN=$(cat "$_ARTDIR/oauth_token.txt")
            echo "  ✅ Bootstrapped CLAUDE_CODE_OAUTH_TOKEN from artifact"
        fi
        [ -z "${CLAUDE_CREDENTIALS_JSON:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && \
            echo "  ⚠️ Artifact found but contained no token files"
    else
        echo "  ▫️ Artifact bootstrap skipped (no successful grant-secrets run found yet)"
    fi
    rm -rf "$_ARTDIR"
fi

# ── Auth from Codespaces secrets ─────────────────────────────────────────────
echo "🔑 Claude auth..."
bash "$DOTFILES_DIR/claude-auth.sh"
if [ -n "${ANTHROPIC_API_KEY:-}" ] && { [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]; }; then
    echo "  ℹ️ ANTHROPIC_API_KEY is also set — if Claude asks about it, decline to keep subscription billing"
fi

# ── Full-auto permission mode + skip first-run prompts ───────────────────────
echo "⚙️  Claude settings (bypassPermissions, onboarding)..."
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
CLAUDE_SETTINGS_FILE="$SETTINGS" python3 <<'PY' || echo "  ⚠️ settings.json not valid JSON — LEFT UNTOUCHED (fix or delete it, then rerun)"
import json, os, sys
p = os.environ["CLAUDE_SETTINGS_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    # Never clobber an unparseable non-trivial file (mid-write/hand-edited).
    if os.path.getsize(p) > 2:
        sys.exit(3)
    cfg = {}
perms = cfg.get("permissions", {})
perms["defaultMode"] = "bypassPermissions"
cfg["permissions"] = perms
# Suppress the one-time "WARNING: Bypass Permissions mode — 1. No, exit / 2.
# Yes, I accept" startup dialog. In current Claude Code (verified live in a real
# codespace, v2.1.174) the in-app `bypassPermissionsModeAccepted` flag does NOT
# suppress this — only this settings key does. Without it the detached tmux
# Claude sits on that dialog (whose DEFAULT is "No, exit").
cfg["skipDangerousModePermissionPrompt"] = True
# Default model: Opus (the alias auto-tracks the latest Opus). Overridable in
# the running TUI via /model; reset to this on each fresh codespace.
cfg["model"] = os.environ.get("CLAUDE_DEFAULT_MODEL", "opus")
tmp = p + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
print("  ✅ permissions.defaultMode = bypassPermissions (+ skipDangerousModePermissionPrompt, model=%s)" % cfg["model"])
PY

# ~/.claude.json: skip the theme/login onboarding and the bypass-mode
# confirmation dialog so the very first launch goes straight to a prompt.
# This file is Claude's live state (login account, project trust, history) —
# merge only, write atomically, and never touch it if it doesn't parse.
CLAUDE_STATE_FILE="$HOME/.claude.json" python3 <<'PY' || echo "  ⚠️ ~/.claude.json not valid JSON — LEFT UNTOUCHED (Claude state preserved)"
import json, os, sys
p = os.environ["CLAUDE_STATE_FILE"]
try:
    cfg = json.load(open(p)) if os.path.exists(p) else {}
except Exception:
    if os.path.getsize(p) > 2:
        sys.exit(3)
    cfg = {}
cfg["hasCompletedOnboarding"] = True
cfg["bypassPermissionsModeAccepted"] = True
tmp = p + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
print("  ✅ onboarding + bypass-mode confirmation pre-accepted")
PY

# ── OAIProvider config (Machine settings — pre-created, server reads on boot) ─
echo "🔌 Provider config..."
if [ -d "${DOTFILES_VSCODE_ROOT:-/vscode}" ] || [ -d "$HOME/.vscode-remote" ] || [ -n "${CODESPACES:-}" ]; then
    SD="$HOME/.vscode-remote/data/Machine"
elif [ -d "$HOME/.vscode-server" ]; then
    SD="$HOME/.vscode-server/data/Machine"
else
    SD=""
fi
if [ -n "$SD" ]; then
    mkdir -p "$SD"
    [ -f "$SD/settings.json" ] || echo '{}' > "$SD/settings.json"
    SETTINGS_FILE="$SD/settings.json" python3 <<'PY' || echo "  ⚠️ Machine settings.json not valid JSON — LEFT UNTOUCHED"
import json, os, sys
p = os.environ["SETTINGS_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    if os.path.getsize(p) > 2:
        sys.exit(3)
    cfg = {}
pro = []
fw = os.environ.get("FIREWORKS_API_KEY", "")
if fw:
    pro.append({"id": "kimi", "displayName": "kimi", "baseUrl": "https://api.fireworks.ai/inference/v1", "apiKey": fw,
                "models": [{"id": "accounts/fireworks/models/kimi-k2p6", "name": "kimi2.6", "maxInputTokens": 500000, "maxOutputTokens": 4096, "supportsToolCalling": True}]})
oa = os.environ.get("OPENAI_API_KEY", "")
if oa:
    pro.append({"id": "openai", "displayName": "OpenAI", "baseUrl": "https://api.openai.com/v1", "apiKey": oa,
                "models": [{"id": "gpt-4o", "name": "GPT-4o", "maxInputTokens": 128000, "maxOutputTokens": 16384, "supportsToolCalling": True}]})
an = os.environ.get("ANTHROPIC_API_KEY", "")
if an:
    pro.append({"id": "anthropic", "displayName": "Anthropic", "baseUrl": "https://api.anthropic.com/v1", "apiKey": an,
                "models": [{"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4", "maxInputTokens": 200000, "maxOutputTokens": 8192, "supportsToolCalling": True}]})
if pro:
    cfg["openai-compat-provider.providers"] = pro
    tmp = p + ".tmp." + str(os.getpid())
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=4)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
    print(f"  ✅ {len(pro)} provider(s) written to Machine settings")
else:
    print("  ℹ️ no provider API keys found")
PY
else
    echo "  ℹ️ not a codespace/devcontainer — skipping Machine settings"
fi

# ── VS Code extensions (background — server doesn't exist yet at this point) ─
echo "🧩 VS Code extensions: launching background installer (log: ~/.dotfiles-vscode-setup.log)"
( nohup bash "$DOTFILES_DIR/vscode-setup.sh" >/dev/null 2>&1 & ) 2>/dev/null

# ── Idle timeout + smart keep-alive ──────────────────────────────────────────
echo "⏰ Keep-alive..."
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GH_CODESPACE_PAT:-}" ]; then
    curl -s -o /dev/null -X PATCH \
        -H "Authorization: Bearer $GH_CODESPACE_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/user/codespaces/$CODESPACE_NAME" \
        -d '{"idle_timeout_minutes":15}' \
        && echo "  ✅ idle timeout baseline set to 15 min" \
        || echo "  ⚠️ could not set idle timeout"
    ( nohup bash "$DOTFILES_DIR/cs_keepalive.sh" >>/tmp/.cs_keepalive.log 2>&1 & ) 2>/dev/null
    echo "  ✅ smart keep-alive started (240 min while Claude works / 15 min idle)"
else
    echo "  ▫️ GH_CODESPACE_PAT not set — keep-alive inactive (add it at github.com/settings/codespaces)"
fi

# ── Persistent Claude Code TUI in tmux (survives closing the browser/VS Code) ─
echo "🖥️  Claude in tmux..."
bash "$DOTFILES_DIR/claude-tmux.sh"

# ── git + gh CLI with full-scope PAT ─────────────────────────────────────────
echo "🔗 git/gh..."
if [ -n "${GH_CODESPACE_PAT:-}" ]; then
    git config --global credential.helper store
    GIT_USER=$(GH_TOKEN="$GH_CODESPACE_PAT" gh api /user --jq '.login' 2>/dev/null || echo "sylt613")
    printf 'https://%s:%s@github.com\n' "$GIT_USER" "$GH_CODESPACE_PAT" > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
    echo "  ✅ git + gh wired with full-scope PAT (user: $GIT_USER)"
else
    echo "  ▫️ GH_CODESPACE_PAT not set — using repo-scoped default token"
fi

# ── Shell rc hook: PATH, GH_TOKEN, and per-shell self-healing ────────────────
echo "🐚 Shell init hook..."
write_rc_block() {
    local f="$1"
    [ -f "$f" ] || touch "$f"
    sed -i '/# >>> ai-dotfiles >>>/,/# <<< ai-dotfiles <<</d' "$f" 2>/dev/null
    cat >> "$f" <<EOF
# >>> ai-dotfiles >>>
export PATH="\$HOME/.local/bin:\$PATH"
if [ -n "\${GH_CODESPACE_PAT:-}" ]; then export GH_TOKEN="\$GH_CODESPACE_PAT"; fi
export AI_DOTFILES_DIR="$DOTFILES_DIR"
# claude-tui: attach to the persistent full-auto Claude session (starts it if needed)
claude-tui() { [ -f "\$AI_DOTFILES_DIR/claude-tmux.sh" ] && bash "\$AI_DOTFILES_DIR/claude-tmux.sh" >/dev/null 2>&1; tmux attach -t "\${CLAUDE_TMUX_SESSION:-claude}"; }
# claude: route the bare interactive TUI through a PER-REPO, persistent tmux
# session in full-auto (bypassPermissions). It stays running when you exit or
# close the terminal — type 'claude' again in the same repo to reattach.
# Utility/piped/arg'd calls (claude --version, claude -p, nested-in-tmux) pass
# straight through to the real CLI. Escape hatch: CLAUDE_NO_TMUX=1.
claude() {
    local real; real="\$(command -v claude 2>/dev/null)"
    if [ -z "\$real" ] || ! command -v tmux >/dev/null 2>&1 || [ -n "\${TMUX:-}" ] || [ -n "\${CLAUDE_NO_TMUX:-}" ] || [ "\$#" -gt 0 ] || [ ! -t 1 ]; then command claude "\$@"; return; fi
    local root; root="\$(git rev-parse --show-toplevel 2>/dev/null)"; [ -n "\$root" ] || root="\$PWD"
    local sess="claude-\$(printf '%s' "\$(basename "\$root")" | tr -c 'A-Za-z0-9_-' '-')"
    tmux has-session -t "\$sess" 2>/dev/null || tmux new-session -d -s "\$sess" -c "\$root" "\$real --permission-mode bypassPermissions; exec bash -i"
    tmux attach -t "\$sess"
}
# claude-fable: quick full-auto Claude on the Fable model (not in the /model picker; default stays Opus)
claude-fable() { claude --model fable "\$@"; }
if [ -f "\$AI_DOTFILES_DIR/session-init.sh" ]; then . "\$AI_DOTFILES_DIR/session-init.sh"; fi
# <<< ai-dotfiles <<<
EOF
}
write_rc_block "$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && write_rc_block "$HOME/.zshrc"
echo "  ✅ ~/.bashrc hook installed (re-seeds auth / extension / keep-alive on every shell)"

# ── ai-check verifier ────────────────────────────────────────────────────────
install -m 755 "$DOTFILES_DIR/ai-check" "$HOME/.local/bin/ai-check" 2>/dev/null \
    && echo "🩺 Run 'ai-check' in any terminal to verify the setup"

echo "✅ Done! ($(date '+%F %T'))"
exit 0
