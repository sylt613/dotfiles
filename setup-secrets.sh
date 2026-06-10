#!/bin/bash
# One-command Codespaces secret setup. Run this ON YOUR OWN MACHINE (laptop /
# any box where you're logged into Claude Code and the gh CLI) — NOT inside a
# codespace:
#
#   bash setup-secrets.sh              # first-time setup (set secrets + grant all repos)
#   bash setup-secrets.sh --grant      # grant all current repos (re-run for new repos)
#
# What it sets:
#   CLAUDE_CREDENTIALS_JSON  if ~/.claude/.credentials.json exists locally
#                            (Linux installs — best option, has refresh token)
#   CLAUDE_CODE_OAUTH_TOKEN  otherwise (macOS keeps creds in Keychain): you
#                            run `claude setup-token` and paste the result
#   GH_CODESPACE_PAT         optional, prompted (Enter to skip)
#
# NOTE: GitHub user-level Codespace secrets can only be granted to SPECIFIC
# repos (GitHub doesn't offer "all repos" for user secrets the way org secrets
# work). This script grants your token to ALL your current repos automatically.
# When you create a NEW repo, re-run: bash setup-secrets.sh --grant
#
# The ONE thing no script/API can do: the "Automatically install dotfiles"
# toggle at https://github.com/settings/codespaces — GitHub has no API for it.
# Check it once by hand (skip if your codespaces already run dotfiles).

set -u

command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not installed → https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh not logged in — run: gh auth login"; exit 1; }

# Managing user-level Codespaces secrets needs the 'codespace' scope.
if ! gh auth status 2>&1 | grep -q "codespace"; then
    echo "ℹ️  adding 'codespace' scope to gh (a browser may open once)..."
    gh auth refresh -h github.com -s codespace || { echo "❌ could not get codespace scope"; exit 1; }
fi

# ── Grant-all-repos helper (works without knowing secret values) ──────────────
# GitHub user secrets are always "selected" visibility; we must add repos
# explicitly. This function grants every current repo access to a given secret.
grant_all_repos() {
    local name="$1"
    echo "  🔗 granting $name to all current repos..."
    local repo_ids
    repo_ids=$(gh api /user/repos --paginate --jq '.[].id' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [ -z "$repo_ids" ]; then
        echo "    ⚠️ could not list repos — skipping repo grant"
        return
    fi
    local count
    count=$(echo "$repo_ids" | tr ',' '\n' | wc -l | tr -d ' ')
    # Build JSON array of IDs
    local payload
    payload=$(python3 -c "
import sys
ids = [int(x) for x in '$repo_ids'.split(',') if x.strip()]
import json; print(json.dumps({'selected_repository_ids': ids}))
")
    if gh api -X PUT "/user/codespaces/secrets/$name/repositories" --input - <<< "$payload" 2>/dev/null; then
        echo "    ✅ granted to $count repos"
    else
        echo "    ⚠️ API call failed (secret may not exist yet)"
    fi
}

# ── --grant mode: just update repo grants, don't re-set secret values ─────────
if [ "${1:-}" = "--grant" ]; then
    echo "🔗 Granting all Codespaces secrets to all current repos..."
    for s in CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CREDENTIALS_JSON GH_CODESPACE_PAT \
              FLY_API_TOKEN FIREWORKS_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY; do
        # Only grant secrets that exist
        if gh api "/user/codespaces/secrets/$s" >/dev/null 2>&1; then
            grant_all_repos "$s"
        fi
    done
    echo
    echo "✅ Done — all existing secrets granted to all current repos."
    echo "   Tip: re-run 'bash setup-secrets.sh --grant' whenever you create a new repo."
    exit 0
fi

# ── First-time setup: set secret values ───────────────────────────────────────
set_secret() {  # $1 = name, value on stdin
    local name="$1"
    # gh secret set --user --app codespaces — no --visibility flag (user secrets
    # don't support "all repos" visibility; we handle repo grants separately via API)
    if gh secret set "$name" --user --app codespaces; then
        echo "  ✅ $name set"
        grant_all_repos "$name"
    else
        echo "  ❌ failed to set $name"
        return 1
    fi
}

echo "🔑 Claude credentials..."
CRED="$HOME/.claude/.credentials.json"
if [ -f "$CRED" ] && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"]' "$CRED" 2>/dev/null; then
    # base64 -w0 is GNU-only; tr strips newlines portably (macOS/BSD too)
    base64 < "$CRED" | tr -d '\n' | set_secret CLAUDE_CREDENTIALS_JSON
else
    echo "  no local credentials file (normal on macOS — Keychain)."
    echo "  run 'claude setup-token' in another terminal, then paste the sk-ant-oat01-... value:"
    printf "  token: "
    IFS= read -r TOKEN
    case "$TOKEN" in
        sk-ant-oat01-*) printf '%s' "$TOKEN" | set_secret CLAUDE_CODE_OAUTH_TOKEN ;;
        *) echo "  ⚠️ that doesn't look like a setup-token value — skipped" ;;
    esac
fi

echo "🔗 GH_CODESPACE_PAT (optional — keep-alive + git on private repos)..."
printf "  paste a classic PAT with repo+codespace scopes, or press Enter to skip: "
IFS= read -r PAT
if [ -n "$PAT" ]; then
    printf '%s' "$PAT" | set_secret GH_CODESPACE_PAT
else
    echo "  ▫️ skipped"
fi

echo
echo "📋 Your Codespaces secrets:"
gh api /user/codespaces/secrets --jq '.secrets[] | "   • \(.name)"' 2>/dev/null
echo
echo "⚠️  Last manual step (no API exists for it): make sure"
echo "   https://github.com/settings/codespaces has 'Automatically install"
echo "   dotfiles' checked with sylt613/dotfiles selected."
echo "   Then create a NEW codespace and run: ai-check"
echo
echo "💡 When you create a NEW repo, run: bash setup-secrets.sh --grant"
