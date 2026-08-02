#!/bin/bash
# claude-relogin.sh — get a real Claude *account record* onto this box, so the
# interactive /model picker can see your plan and stop gating Fable.
#
# WHY THIS EXISTS
#   `claude setup-token` auth (invariant 1) is rotation-proof and keeps every
#   codespace logged in — but the token carries NO account record. Because of
#   that, `oauthAccount` in ~/.claude.json is never populated, and the
#   interactive /model picker reads exactly that record to decide plan
#   entitlement. Finding nothing, it assumes no subscription and gates Fable
#   behind "Usage Credits" — and when extra usage is disabled org-wide, Fable
#   simply isn't selectable at all.
#
#   Nothing errors when this happens. Inference works, /usage shows the plan
#   correctly, and even `claude -p --model fable` runs real Fable. ONLY the
#   picker is broken, which is why this can sit undetected for months.
#   `ai-check` now flags it under "Plan entitlement".
#
#   Only an interactive /login writes a credential carrying that record.
#
# USAGE
#   claude-relogin.sh            prepare this box, then run /login
#   claude-relogin.sh --save     after /login: verify + push to secrets (all repos)
#   claude-relogin.sh --restore  undo the prepare step
#   claude-relogin.sh --status   just report what the picker can currently see

CLAUDE_DIR="$HOME/.claude"
CRED="$CLAUDE_DIR/.credentials.json"
SETTINGS="$CLAUDE_DIR/settings.json"
BACKUP="$CLAUDE_DIR/settings.json.pre-relogin"
DOTFILES_REPO="sylt613/dotfiles"

has_account() {
    python3 - "$HOME/.claude.json" <<'PY' 2>/dev/null
import json, sys
try:
    sys.exit(0 if json.load(open(sys.argv[1])).get("oauthAccount") else 1)
except Exception:
    sys.exit(1)
PY
}

cred_live() {
    python3 - "$CRED" <<'PY' 2>/dev/null
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))["claudeAiOauth"]
except Exception:
    sys.exit(1)
e = d.get("expiresAt", 0)
sys.exit(0 if d.get("accessToken") and e and e / 1000 > time.time() else 1)
PY
}

show_status() {
    echo "── What the /model picker can see right now"
    if has_account; then
        python3 - "$HOME/.claude.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))["oauthAccount"]
print(f"  ✅ account record present")
print(f"     organizationType     : {a.get('organizationType')}")
print(f"     rateLimitTier        : {a.get('organizationRateLimitTier')}")
PY
    else
        echo "  ⚠️ oauthAccount is null — token-only auth, picker will gate Fable"
    fi
    if [ -f "$CRED" ]; then
        if cred_live; then
            echo "  ✅ credentials.json is live"
        else
            echo "  ⚠️ credentials.json is EXPIRED (it outranks every other auth path)"
        fi
    else
        echo "  ▫️ no credentials.json"
    fi
    if [ -f "$SETTINGS" ] && grep -q '"CLAUDE_CODE_OAUTH_TOKEN"' "$SETTINGS" 2>/dev/null; then
        echo "  ▫️ CLAUDE_CODE_OAUTH_TOKEN pinned in settings.json (fallback auth)"
    fi
}

# ── --status ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--status" ]; then
    show_status
    exit 0
fi

# ── --restore ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "--restore" ]; then
    if [ -f "$BACKUP" ]; then
        install -m 600 "$BACKUP" "$SETTINGS" && rm -f "$BACKUP"
        echo "✅ restored $SETTINGS from the pre-relogin backup"
        echo "   (the OAuth token pin is back — auth works, picker gating returns)"
    else
        echo "⚠️ no backup at $BACKUP — nothing to restore."
        echo "   To re-pin the token from the Codespaces secret instead:"
        echo "     bash \"\${AI_DOTFILES_DIR:-~/dotfiles}/claude-auth.sh\""
    fi
    exit 0
fi

# ── --save ──────────────────────────────────────────────────────────────────
# Propagate the freshly-minted credential everywhere, so this fix survives new
# codespaces and applies to every repo — not just the box you logged in on.
if [ "${1:-}" = "--save" ]; then
    echo "── Verifying the login actually produced an account record"
    if ! has_account; then
        echo "❌ oauthAccount is STILL null in ~/.claude.json."
        echo "   The /login didn't take. Common cause: CLAUDE_CODE_OAUTH_TOKEN was"
        echo "   still set in the environment, so Claude never used the new login."
        echo "   Start Claude with it unset and log in again:"
        echo "     env -u CLAUDE_CODE_OAUTH_TOKEN claude"
        exit 1
    fi
    if ! cred_live; then
        echo "❌ $CRED is missing or already expired — refusing to publish a dead"
        echo "   snapshot (that is exactly the bug this whole change exists to stop)."
        exit 1
    fi
    show_status
    echo

    if ! command -v gh >/dev/null 2>&1; then
        echo "⚠️ gh not available — this box is fixed, but other codespaces won't"
        echo "   inherit it. Re-run 'claude-relogin.sh --save' where gh works."
        exit 1
    fi

    RAW=$(cat "$CRED")
    B64=$(base64 -w0 < "$CRED")
    rc=0

    # User Codespaces secret — raw JSON (what claude-auth.sh seeds from).
    if printf '%s' "$RAW" | gh secret set CLAUDE_CREDENTIALS_JSON --user --app codespaces 2>/dev/null; then
        echo "  ✅ user Codespaces secret CLAUDE_CREDENTIALS_JSON updated"
    else
        echo "  ❌ could not update the user Codespaces secret (needs 'codespace' scope)"; rc=1
    fi

    # Repo Actions secret — base64. grant-secrets RESTORES the user secret from
    # this copy, and bakes it into the bootstrap artifact. If it isn't updated
    # too, tomorrow's cron happily resurrects the dead snapshot.
    if printf '%s' "$B64" | gh secret set CLAUDE_CREDENTIALS_JSON --repo "$DOTFILES_REPO" --app actions 2>/dev/null; then
        echo "  ✅ repo Actions secret on $DOTFILES_REPO updated (base64)"
    else
        echo "  ❌ could not update the repo Actions secret on $DOTFILES_REPO"; rc=1
    fi

    # Re-grant to every repo and refresh the bootstrap artifact. Also repairs
    # the repo selection, in case setting the secret narrowed it.
    if gh workflow run grant-secrets.yml -R "$DOTFILES_REPO" >/dev/null 2>&1; then
        echo "  ✅ grant-secrets dispatched — re-grants to all repos + refreshes the artifact"
        echo "     watch: gh run list --repo $DOTFILES_REPO --workflow grant-secrets.yml"
    else
        echo "  ⚠️ could not dispatch grant-secrets — run it manually:"
        echo "     gh workflow run grant-secrets.yml -R $DOTFILES_REPO"
    fi

    echo
    if [ "$rc" -eq 0 ]; then
        echo "✅ Saved. New codespaces on any repo now seed a live, account-bearing"
        echo "   credential, so the /model picker sees your plan and Fable is selectable."
    else
        echo "⚠️ Partially saved — see the ❌ lines above. This box is fixed either way."
    fi
    exit "$rc"
fi

# ── default: prepare for /login ─────────────────────────────────────────────
echo "── Preparing this box for an interactive /login"

if has_account && cred_live; then
    echo "  ✅ You already have a live credential AND an account record."
    echo "     Nothing to do — the picker can already see your plan."
    echo
    show_status
    exit 0
fi

# 1. A dead credential outranks every other auth path — clear it out.
if [ -f "$CRED" ] && ! cred_live; then
    rm -f "$CRED"
    echo "  ✅ removed expired $CRED (it outranks and shadows all other auth)"
elif [ -f "$CRED" ]; then
    echo "  ▫️ keeping live $CRED"
fi

# 2. Unpin the token, or Claude keeps using it and /login silently does nothing.
if [ -f "$SETTINGS" ] && grep -q '"CLAUDE_CODE_OAUTH_TOKEN"' "$SETTINGS" 2>/dev/null; then
    cp -p "$SETTINGS" "$BACKUP" && chmod 600 "$BACKUP"
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
env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
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
        0) echo "  ✅ unpinned CLAUDE_CODE_OAUTH_TOKEN (backup: $BACKUP)" ;;
        3) echo "  ❌ $SETTINGS is not valid JSON — left untouched. Fix it, then re-run."; exit 1 ;;
        *) echo "  ❌ failed to rewrite $SETTINGS"; exit 1 ;;
    esac
else
    echo "  ▫️ no token pinned in settings.json"
fi

echo
echo "── Next steps (the /login itself must be interactive — nothing can do it for you)"
echo
echo "  1. Quit every running Claude Code session, including the tmux one:"
echo "       tmux kill-session -t \"\${CLAUDE_TMUX_SESSION:-claude}\" 2>/dev/null"
echo
echo "  2. Start Claude with the token explicitly unset and log in:"
echo "       env -u CLAUDE_CODE_OAUTH_TOKEN claude"
echo "       /login"
echo
echo "     In VS Code, fully reload the window afterwards (Cmd/Ctrl+Shift+P →"
echo "     'Developer: Reload Window') — the extension caches entitlement, which"
echo "     is why people in the upstream issue needed a full restart."
echo
echo "  3. Confirm it took, then publish it to every repo:"
echo "       claude-relogin.sh --save"
echo
echo "  If anything goes wrong, 'claude-relogin.sh --restore' puts the token back."
