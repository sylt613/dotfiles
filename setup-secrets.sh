#!/bin/bash
# One-command Codespaces secret setup. Run this ON YOUR OWN MACHINE (laptop /
# any box where you're logged into Claude Code and the gh CLI) — NOT inside a
# codespace:
#
#   bash setup-secrets.sh owner/repo1 [owner/repo2 ...]
#
# It uploads your Claude login to your GitHub *user* Codespaces secrets and
# grants them to every repo you list (merging with repos already granted, so
# re-running never removes access). After this, codespaces on those repos log
# in by themselves.
#
# What it sets:
#   CLAUDE_CREDENTIALS_JSON  if ~/.claude/.credentials.json exists locally
#                            (Linux installs — best option, has refresh token)
#   CLAUDE_CODE_OAUTH_TOKEN  otherwise (macOS keeps creds in Keychain): you
#                            run `claude setup-token` and paste the result
#   GH_CODESPACE_PAT         optional, prompted (Enter to skip)
#
# The ONE thing no script/API can do: the "Automatically install dotfiles"
# toggle at https://github.com/settings/codespaces — GitHub has no API for it.
# Check it once by hand (skip if your codespaces already run dotfiles).

set -u

REPOS=("$@")
if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "usage: bash setup-secrets.sh <owner/repo> [more repos ...]"
    echo "   eg: bash setup-secrets.sh sylt613/dotfiles sylt613/myproject"
    exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not installed → https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh not logged in — run: gh auth login"; exit 1; }

# Managing user-level Codespaces secrets needs the 'codespace' scope.
if ! gh auth status 2>&1 | grep -q "codespace"; then
    echo "ℹ️  adding 'codespace' scope to gh (a browser may open once)..."
    gh auth refresh -h github.com -s codespace || { echo "❌ could not get codespace scope"; exit 1; }
fi

# Merge the repos being granted with any already granted to the secret, so
# re-running for a new repo never revokes the old ones.
merged_repos() {  # $1 = secret name → comma-separated repo list on stdout
    {
        gh api "/user/codespaces/secrets/$1/repositories" \
            --jq '.repositories[].full_name' 2>/dev/null
        printf '%s\n' "${REPOS[@]}"
    } | sort -u | grep . | tr '\n' ',' | sed 's/,$//'
}

set_secret() {  # $1 = name, value on stdin
    local name="$1" repos
    repos=$(merged_repos "$name")
    if gh secret set "$name" --user --app codespaces --repos "$repos"; then
        echo "  ✅ $name set + granted to: $repos"
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
echo "📋 Your user Codespaces secrets now:"
gh api /user/codespaces/secrets --jq '.secrets[].name' 2>/dev/null | sed 's/^/   • /'
echo
echo "⚠️  Last manual step (no API exists for it): make sure"
echo "   https://github.com/settings/codespaces has 'Automatically install"
echo "   dotfiles' checked with sylt613/dotfiles selected."
echo "   Then create a NEW codespace and run: ai-check"
