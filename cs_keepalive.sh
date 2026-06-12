#!/bin/bash
# Smart keep-alive: while Claude is actively working the codespace idle timeout
# is raised to 240 min (so long tasks aren't killed mid-run); when Claude goes
# quiet it drops back to 15 min (stops fast, saves money). "Working" = it either
# wrote a transcript line in the last 2 min (covers the CLI in tmux AND the VS
# Code extension) OR its tmux TUI printed something recently (covers long
# thinking / tool runs that don't flush a transcript line for a while). An idle
# Claude sitting at its prompt does neither → the machine is allowed to stop.
# Requires GH_CODESPACE_PAT (full-scope PAT) — the built-in GITHUB_TOKEN has
# no `codespace` scope. Singleton via flock; survives nothing — restarted by
# session-init.sh on the first terminal after a codespace resume.

[ -n "${CODESPACE_NAME:-}" ] || exit 0
[ -n "${GH_CODESPACE_PAT:-}" ] || exit 0

exec 9>"/tmp/.cs_keepalive.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

SESSION="${CLAUDE_TMUX_SESSION:-claude}"
ACTIVE_WINDOW="${CS_KEEPALIVE_ACTIVE_WINDOW:-150}"  # secs of tmux silence ⇒ idle

set_timeout() {
    curl -s -o /dev/null -X PATCH \
        -H "Authorization: Bearer $GH_CODESPACE_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/user/codespaces/$CODESPACE_NAME" \
        -d "{\"idle_timeout_minutes\":$1}"
}

# 0 (true) if the Claude tmux pane emitted output within ACTIVE_WINDOW seconds.
tmux_recently_active() {
    command -v tmux >/dev/null 2>&1 || return 1
    local act now
    act=$(tmux display-message -p -t "$SESSION" '#{window_activity}' 2>/dev/null) || return 1
    case "$act" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s)
    [ "$((now - act))" -lt "$ACTIVE_WINDOW" ]
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
    if [ -n "$WROTE" ] || tmux_recently_active; then WANT=240; fi
    if [ "$CURRENT" != "$WANT" ]; then
        set_timeout "$WANT" && CURRENT="$WANT"
    fi
done
