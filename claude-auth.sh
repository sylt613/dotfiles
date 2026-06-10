#!/bin/bash
# Seeds Claude Code auth from Codespaces secrets. Idempotent — safe to re-run
# any time (install.sh runs it at creation, session-init.sh re-runs it if a
# secret shows up later, e.g. after the user adds/grants a secret and restarts).
#
# Supported secrets (set at https://github.com/settings/codespaces and GRANT
# them to every repository you open codespaces on):
#   CLAUDE_CODE_OAUTH_TOKEN   output of `claude setup-token` (sk-ant-oat01-…)
#   CLAUDE_CREDENTIALS_JSON   contents of ~/.claude/.credentials.json from a
#                             logged-in machine — raw JSON or base64, both work

STATE_DIR="$HOME/.dotfiles-state"
CLAUDE_DIR="$HOME/.claude"
CRED="$CLAUDE_DIR/.credentials.json"
mkdir -p "$STATE_DIR" "$CLAUDE_DIR"
configured=""

cred_valid() {
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"]' "$1" 2>/dev/null
}

cred_expiry() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("claudeAiOauth",{}).get("expiresAt",0))' "$1" 2>/dev/null || echo 0
}

# ── Full credentials JSON (carries refresh token → survives token expiry) ────
if [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]; then
    tmp=$(mktemp)
    # Accept raw JSON first, then try base64-decoding it.
    printf '%s' "$CLAUDE_CREDENTIALS_JSON" > "$tmp"
    if ! cred_valid "$tmp"; then
        printf '%s' "$CLAUDE_CREDENTIALS_JSON" | base64 -d > "$tmp" 2>/dev/null || true
    fi
    if cred_valid "$tmp"; then
        if [ ! -f "$CRED" ] || [ "$(cred_expiry "$tmp")" -gt "$(cred_expiry "$CRED")" ]; then
            install -m 600 "$tmp" "$CRED"
            echo "  ✅ ~/.claude/.credentials.json seeded from CLAUDE_CREDENTIALS_JSON"
        else
            echo "  ✅ keeping existing credentials.json (newer than the secret)"
        fi
        configured=1
        python3 - "$CRED" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))["claudeAiOauth"]
exp = d.get("expiresAt", 0)
if exp and exp / 1000 < time.time():
    if d.get("refreshToken"):
        print("  ℹ️ access token in the secret is expired — Claude will auto-refresh it")
    else:
        print("  ⚠️ access token EXPIRED and no refresh token — re-export CLAUDE_CREDENTIALS_JSON!")
PY
    else
        echo "  ⚠️ CLAUDE_CREDENTIALS_JSON is not valid JSON (tried raw and base64) — skipping"
    fi
    rm -f "$tmp"
fi

# ── Long-lived OAuth token (from `claude setup-token`) ───────────────────────
# Written into ~/.claude/settings.json "env" so BOTH the CLI and the VS Code
# extension pick it up, regardless of how their processes inherit environment.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    SETTINGS="$CLAUDE_DIR/settings.json"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    if CLAUDE_SETTINGS_FILE="$SETTINGS" python3 <<'PY'
import json, os
p = os.environ["CLAUDE_SETTINGS_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    cfg = {}
env = cfg.get("env", {})
env["CLAUDE_CODE_OAUTH_TOKEN"] = os.environ["CLAUDE_CODE_OAUTH_TOKEN"]
cfg["env"] = env
json.dump(cfg, open(p, "w"), indent=2)
PY
    then
        chmod 600 "$SETTINGS"
        echo "  ✅ CLAUDE_CODE_OAUTH_TOKEN wired into ~/.claude/settings.json env (CLI + extension)"
        configured=1
    else
        echo "  ⚠️ failed to write OAuth token into ~/.claude/settings.json"
    fi
fi

if [ -n "$configured" ]; then
    touch "$STATE_DIR/auth-configured"
else
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "  ℹ️ no OAuth secrets, but ANTHROPIC_API_KEY is set — Claude Code will offer API-key billing"
    else
        echo "  ⚠️ No Claude auth found. Run 'claude setup-token' on a logged-in machine, then add"
        echo "     CLAUDE_CODE_OAUTH_TOKEN at https://github.com/settings/codespaces and GRANT it to your repos."
    fi
fi

exit 0
