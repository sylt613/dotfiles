#!/bin/bash
# Smart keep-alive: while Claude is actively writing session files the
# codespace idle timeout is raised to 240 min (so long tasks aren't killed);
# when Claude goes quiet it drops back to 15 min (stops fast, saves money).
# Requires GH_CODESPACE_PAT (full-scope PAT) — the built-in GITHUB_TOKEN has
# no `codespace` scope. Singleton via flock; survives nothing — restarted by
# session-init.sh on the first terminal after a codespace resume.

[ -n "${CODESPACE_NAME:-}" ] || exit 0
[ -n "${GH_CODESPACE_PAT:-}" ] || exit 0

exec 9>"/tmp/.cs_keepalive.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

set_timeout() {
    curl -s -o /dev/null -X PATCH \
        -H "Authorization: Bearer $GH_CODESPACE_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/user/codespaces/$CODESPACE_NAME" \
        -d "{\"idle_timeout_minutes\":$1}"
}

CURRENT=""
while true; do
    MARKER=$(mktemp /tmp/.cs_mark.XXXXXX)
    sleep 120
    # Claude writes .jsonl transcript files while it is working.
    WROTE=$(find "$HOME/.claude/projects" "$HOME/.claude/sessions" \
        -newer "$MARKER" -name '*.jsonl' 2>/dev/null | head -1)
    rm -f "$MARKER"
    WANT=15
    [ -n "$WROTE" ] && WANT=240
    if [ "$CURRENT" != "$WANT" ]; then
        set_timeout "$WANT" && CURRENT="$WANT"
    fi
done
