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

cred_expired() {  # true if the file's accessToken expiry is in the past
    python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])).get("claudeAiOauth",{}); e=d.get("expiresAt",0); sys.exit(0 if e and e/1000 < time.time() else 1)' "$1" 2>/dev/null
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
        # CRITICAL: the credentials file OUTRANKS CLAUDE_CODE_OAUTH_TOKEN in
        # Claude Code's auth order, and refresh tokens are single-use — once
        # any install rotates the family, the snapshot in the secret is dead
        # and seeding it SHADOWS the (valid, 1-year) setup-token → login
        # screen. So: NEVER seed an expired credential. Not "not when a token
        # is present" — never. A dead snapshot has no value in any scenario
        # (its refresh token is dead too), and it outranks every other auth
        # path, so seeding it can only ever break something. The old
        # token-present condition let the dead June snapshot land on any box
        # whose token env var wasn't visible yet at seed time.
        if cred_expired "$tmp"; then
            echo "  ⚠️ CLAUDE_CREDENTIALS_JSON is EXPIRED — NOT seeding it (a dead credential outranks and shadows every other auth path)"
            # If an earlier run seeded this same dead snapshot, remove it so it
            # stops shadowing the token. Only a byte-identical file is ours to
            # remove — a live file Claude has refreshed never matches.
            if [ -f "$CRED" ] && cmp -s "$tmp" "$CRED"; then
                rm -f "$CRED"
                if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
                    echo "     removed previously-seeded dead credentials file — token auth now active"
                else
                    echo "     removed previously-seeded dead credentials file — run /login to re-authenticate"
                fi
            fi
        elif [ ! -f "$CRED" ] || [ "$(cred_expiry "$tmp")" -gt "$(cred_expiry "$CRED")" ]; then
            install -m 600 "$tmp" "$CRED"
            echo "  ✅ ~/.claude/.credentials.json seeded from CLAUDE_CREDENTIALS_JSON"
            configured=1
        else
            echo "  ✅ keeping existing credentials.json (newer than the secret)"
            configured=1
        fi
        [ -f "$CRED" ] && python3 - "$CRED" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))["claudeAiOauth"]
exp = d.get("expiresAt", 0)
if exp and exp / 1000 < time.time():
    if d.get("refreshToken"):
        print("  ℹ️ access token in the secret is expired — Claude will try to refresh it (works only if no other install rotated it first)")
    else:
        print("  ⚠️ access token EXPIRED and no refresh token — re-export CLAUDE_CREDENTIALS_JSON!")
PY
    else
        echo "  ⚠️ CLAUDE_CREDENTIALS_JSON is not valid JSON (tried raw and base64) — skipping"
    fi
    rm -f "$tmp"
fi

# ── Long-lived OAuth token (from `claude setup-token`) ───────────────────────
# Pinned into ~/.claude/settings.json "env" as a FALLBACK ONLY — see invariant 6
# in CLAUDE.md. A setup-token authenticates inference perfectly, but it carries
# no account record: `oauthAccount` in ~/.claude.json stays null, and the
# interactive /model picker reads THAT to decide plan entitlement. With no
# record it assumes no subscription and gates Fable behind "Usage Credits" —
# which, with extra usage off org-wide, means Fable is simply unavailable in the
# picker even though `--model fable` works fine. A live credentials.json (what
# an interactive /login writes) does carry the record, so whenever one exists we
# REMOVE the pin and leave the credential authoritative.
cred_live() { [ -f "$1" ] && cred_valid "$1" && ! cred_expired "$1"; }

SETTINGS="$CLAUDE_DIR/settings.json"

if cred_live "$CRED"; then
    # Live login credential present — unpin the token so it can't shadow the
    # account record. The token stays in the Codespaces secret for recovery.
    if [ -f "$SETTINGS" ] && grep -q '"CLAUDE_CODE_OAUTH_TOKEN"' "$SETTINGS" 2>/dev/null; then
        CLAUDE_SETTINGS_FILE="$SETTINGS" python3 <<'PY'
import json, os, sys
p = os.environ["CLAUDE_SETTINGS_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    if os.path.getsize(p) > 2:      # invariant 5: never clobber a live file
        sys.exit(3)
    cfg = {}
env = cfg.get("env", {})
if env.pop("CLAUDE_CODE_OAUTH_TOKEN", None) is None:
    sys.exit(4)                     # nothing to do
if env:
    cfg["env"] = env
else:
    cfg.pop("env", None)
tmp = p + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
        case $? in
            0) echo "  ✅ live login credential present — unpinned CLAUDE_CODE_OAUTH_TOKEN so the /model picker sees your plan" ;;
            3) echo "  ⚠️ ~/.claude/settings.json is not valid JSON — left untouched" ;;
        esac
    fi
    configured=1
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    CLAUDE_SETTINGS_FILE="$SETTINGS" python3 <<'PY'
import json, os, sys
p = os.environ["CLAUDE_SETTINGS_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    if os.path.getsize(p) > 2:
        sys.exit(3)
    cfg = {}
env = cfg.get("env", {})
env["CLAUDE_CODE_OAUTH_TOKEN"] = os.environ["CLAUDE_CODE_OAUTH_TOKEN"]
cfg["env"] = env
tmp = p + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
    rc=$?
    if [ "$rc" -eq 0 ]; then
        chmod 600 "$SETTINGS"
        echo "  ✅ CLAUDE_CODE_OAUTH_TOKEN wired into ~/.claude/settings.json env (CLI + extension)"
        echo "     ℹ️ token-only auth: inference works everywhere, but the /model picker"
        echo "        cannot see your plan and will gate Fable. Run 'claude-relogin.sh'"
        echo "        then /login to get a real account record."
        configured=1
    elif [ "$rc" -eq 3 ]; then
        echo "  ⚠️ ~/.claude/settings.json is not valid JSON — left untouched; token available via env only"
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
