#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Keep this Codespace alive while — and only while — Claude Code is working.
#
# WHY THIS SHAPE (read before "simplifying" it):
#
#   The previous version of this script tried to raise idle_timeout_minutes via
#   PATCH /user/codespaces/{name}. That DOES NOT WORK and never did:
#     * idle_timeout_minutes is not an accepted body param on that endpoint
#       (only machine / display_name / recent_folders are).
#     * The API still answers 200 and silently drops the field, so the old
#       `set_timeout ... && CURRENT=$WANT` always "succeeded" and never retried.
#     * `gh codespace edit` has no --idle-timeout flag at all.
#     * A codespace's idle timeout is fixed when it is CREATED and is immutable
#       for its whole life. Verified empirically 2026-07-31: PATCH returned 200
#       and a follow-up GET still read idle_timeout_minutes=30.
#   Net effect: the old keep-alive was a no-op that logged nothing.
#
#   What actually defers the idle stop is a live CLIENT CONNECTION. Background
#   processes do not count; GitHub is explicit that terminal output only counts
#   while a client is attached. So this script holds a real client connection
#   open: an SSH session to ourselves over `gh codespace ssh`, which also prints
#   a line every 30s so the session is generating terminal traffic, not just
#   sitting idle.
#
# COST: while held, the codespace never idles out, so it bills core-hours
#   continuously. That is why this is conditional — see ACTIVE below.
#
# ACTIVE  = a Claude Code process is running  AND  some session transcript under
#           ~/.claude/projects was appended to within IDLE_WINDOW seconds.
#           Both must hold. Rationale for this signal over the alternatives:
#             - bare process/tmux-session existence: a Claude sitting at its
#               prompt for days would pin the box alive 24/7 and burn money.
#             - tmux #{window_activity}: unreliable here — every session on this
#               box reports "0s ago" because the TUI repaints, so it can never
#               distinguish working from idle.
#             - transcript mtime alone: a leftover file could look fresh after
#               the process is gone; pairing it with the process check fixes it.
#
# FAIL-SAFE: runs as the normal codespace user, never root. Singleton via flock.
#   Every failure is caught and logged; nothing here can signal or kill another
#   process. If it cannot authenticate it logs and keeps retrying rather than
#   exiting, so a late-arriving secret self-heals.
#
# NO SECRETS IN THIS FILE: GH_CODESPACE_PAT comes from the Codespaces user
#   secret of the same name (github.com/settings/codespaces). The built-in
#   GITHUB_TOKEN is not usable — it lacks the `codespace` scope.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

LOG="${CS_KEEPALIVE_LOG:-$HOME/.cs-keepalive.log}"
IDLE_WINDOW="${CS_KEEPALIVE_IDLE_WINDOW:-900}"   # transcript-silence grace before idle
POLL="${CS_KEEPALIVE_POLL:-60}"                  # how often we re-evaluate
SSH_LEASE="${CS_KEEPALIVE_SSH_LEASE:-1800}"      # recycle the held session every 30 min
FORCE_FLAG="${CS_KEEPALIVE_FORCE_FLAG:-$HOME/.cs-keepalive.force}"   # manual override
# CPU (utime+stime jiffies, 100/s) the claude procs must burn in one POLL to
# count as busy. Ported from the Fly watchdog, but the threshold is RAISED:
# Fly defaults to ~1% average, which is fine there. Here the Claude TUI repaints
# constantly (see the tmux note below), so 1% risks reading an idle spinner as
# work and pinning a $0.36/hr box forever. 3% average sits above spinner noise
# and far below real work — measured on this box, four working sessions burned
# ~22% combined. Every decision logs its delta so this can be recalibrated from
# real data rather than guesswork.
BUSY_JIFFIES="${CS_KEEPALIVE_BUSY_JIFFIES:-$(( POLL * 3 ))}"
HEARTBEAT="${CS_KEEPALIVE_HEARTBEAT:-1800}"      # periodic "still here + why" log line

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null || true; }

# Keep the log from growing without bound (it is one line per state change).
trim_log() {
    local n
    n=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 2000 ]; then
        tail -n 500 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
}

[ -n "${CODESPACE_NAME:-}" ] || { log "not a codespace (no CODESPACE_NAME) — exiting"; exit 0; }

# Singleton. If another copy holds the lock, leave quietly.
exec 9>"/tmp/.cs_keepalive.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

log "keepalive starting (pid $$, codespace $CODESPACE_NAME, idle_window=${IDLE_WINDOW}s)"

HOLDER_PID=""
LAST_PAT_WARN=0
# Distinctive marker so we can find our own held sessions and nothing else.
HOLD_MARK="cs-keepalive-hold"

# If a previous supervisor was SIGKILLed (uncatchable, so the trap never ran),
# its ssh child survives as an orphan and would keep the box alive forever with
# nothing watching it. We hold the flock, so any holder alive right now is
# stale by definition.
# True if $1 is us or descends from us. Guards reap_orphans against killing a
# holder that belongs to a *live* supervisor: if the lock file is ever removed
# by hand two copies can run at once, and an unguarded marker-wide `kill -9`
# would let the older one tear down the younger one's session on its way out.
is_ours() {
    local p="$1" guard=0
    while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$guard" -lt 20 ]; do
        [ "$p" = "$$" ] && return 0
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || return 1
        guard=$((guard+1))
    done
    return 1
}

reap_orphans() {
    local n=0 p
    for p in $(pgrep -f "$HOLD_MARK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        is_ours "$p" && continue
        kill -9 "$p" 2>/dev/null && n=$((n+1))
    done
    [ "$n" -gt 0 ] && log "reaped $n orphaned holder process(es) from a previous run"
    return 0
}
reap_orphans

claude_running() {
    pgrep -f '(^|/)claude($| )' >/dev/null 2>&1 \
        || pgrep -f '\.local/bin/claude' >/dev/null 2>&1
}

# Total CPU jiffies (utime+stime) across the real Claude CLI processes.
# `pgrep -x claude` matches comm == "claude" exactly, so it skips tmux, the
# launcher and this script. Verified on this box: comm really is "claude" and
# pgrep -x finds all live sessions. The node fallback catches an npm-installed
# CLI, whose comm is "node" — without it the busy signal silently reads zero.
claude_cpu() {
    local total=0 pid stat
    for pid in $(pgrep -x claude 2>/dev/null); do
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
        stat=${stat##*) }            # strip "pid (comm) "; robust to parens in comm
        set -- $stat                 # after strip: utime=field 12, stime=field 13
        total=$(( total + ${12:-0} + ${13:-0} ))
    done
    for pid in $(pgrep -x node 2>/dev/null); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'claude' || continue
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
        stat=${stat##*) }
        set -- $stat
        total=$(( total + ${12:-0} + ${13:-0} ))
    done
    echo "$total"
}

transcript_fresh() {
    # Any Claude transcript appended to within IDLE_WINDOW seconds?
    local mins=$(( (IDLE_WINDOW + 59) / 60 ))
    [ -n "$(find "$HOME/.claude/projects" "$HOME/.claude/sessions" \
             -name '*.jsonl' -mmin "-$mins" -print -quit 2>/dev/null)" ]
}

# Decide whether the box should stay awake. Mirrors the Fly watchdog's
# should_keep(), MINUS two of its four signals — deliberately.
#
# DROPPED, because they were measured on this box and do not discriminate:
#   * any_attached  — all 4 tmux sessions report session_attached=1 at all
#                     times, so this would be permanently true.
#   * last_tmux_activity — newest pane activity reads 0s ago constantly because
#                     the TUI repaints, so the grace window would never expire.
# Porting either verbatim from the Fly script would pin this codespace awake
# 24/7 and bill around the clock. That is the whole reason they are not here.
#
# KEPT: the force flag, the CPU-burn signal (the good one — it tracks Claude
# actually thinking/streaming/running tools) and the transcript grace window,
# which is the signal already proven in production on this box to flip to idle
# and let it stop.
REASON=""
should_keep() {
    local delta="$1"
    if [ -f "$FORCE_FLAG" ]; then REASON="forced(flag)"; return 0; fi
    if ! claude_running; then REASON="no-claude(cpu ${delta}j)"; return 1; fi
    if [ "$delta" -ge "$BUSY_JIFFIES" ]; then
        REASON="busy(cpu ${delta}j/${BUSY_JIFFIES}j)"; return 0
    fi
    if transcript_fresh; then
        REASON="recent(transcript<${IDLE_WINDOW}s,cpu ${delta}j)"; return 0
    fi
    REASON="idle(transcript>=${IDLE_WINDOW}s,cpu ${delta}j)"; return 1
}

holder_alive() { [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; }

start_holder() {
    if [ -z "${GH_CODESPACE_PAT:-}" ]; then
        # Rate-limit: this is checked every POLL seconds, and a missing secret
        # is a standing condition, not an event. Complain at most every 30 min
        # so the log stays diagnosable instead of becoming a wall of noise.
        local now; now=$(date +%s)
        if [ $(( now - ${LAST_PAT_WARN:-0} )) -ge 1800 ]; then
            LAST_PAT_WARN=$now
            log "WANT-ALIVE but GH_CODESPACE_PAT is unset — cannot hold a session."
            log "  fix: add GH_CODESPACE_PAT (PAT with 'codespace' scope) at github.com/settings/codespaces"
        fi
        return 1
    fi
    # Hold a real client connection open, emitting output so the session is not
    # merely connected but actively producing terminal traffic.
    (
        export GH_TOKEN="$GH_CODESPACE_PAT"
        exec timeout "$SSH_LEASE" gh codespace ssh -c "$CODESPACE_NAME" -- \
            "while true; do echo $HOLD_MARK \$(date -u +%H:%M:%S); sleep 30; done"
    ) >>"$LOG.ssh" 2>&1 &
    HOLDER_PID=$!
    log "holding client session (ssh pid $HOLDER_PID, lease ${SSH_LEASE}s)"
    return 0
}

stop_holder() {
    if holder_alive; then
        kill "$HOLDER_PID" 2>/dev/null
        sleep 1
        kill -9 "$HOLDER_PID" 2>/dev/null
        log "released client session (was pid $HOLDER_PID) — codespace may now idle out"
    fi
    HOLDER_PID=""
    # `timeout` dying does not always take the ssh grandchild with it.
    reap_orphans
}

# Never leave a stray ssh behind if we are stopped.
trap 'stop_holder; log "keepalive exiting"; exit 0' TERM INT

STATE="unknown"
PREV_CPU=-1
LAST_BEAT=0
while true; do
    CUR_CPU=$(claude_cpu)
    if [ "$PREV_CPU" -ge 0 ]; then DELTA=$(( CUR_CPU - PREV_CPU )); else DELTA=0; fi
    [ "$DELTA" -lt 0 ] && DELTA=0        # claude restarted; no meaningful delta
    PREV_CPU=$CUR_CPU

    if should_keep "$DELTA"; then
        if [ "$STATE" != "active" ]; then
            log "AWAKE — $REASON"
            STATE="active"
        fi
        if ! holder_alive; then
            # The SSH_LEASE recycle tears down the local side, but the remote
            # end of the tunnel is this same box: its `while true` loop is
            # reparented to init and only dies on SIGPIPE at its next write.
            # Sweep before re-establishing so recycles cannot accumulate.
            reap_orphans
            start_holder || true   # failure is logged, never fatal
        fi
    else
        if [ "$STATE" != "idle" ]; then
            log "SLEEPABLE — $REASON — releasing, codespace may now idle out"
            STATE="idle"
        fi
        stop_holder
    fi

    # Periodic heartbeat: proves the watchdog is alive even when nothing
    # changes, and records the CPU delta so BUSY_JIFFIES can be calibrated
    # against what an actually-idle Claude looks like on this box.
    NOW_S=$(date +%s)
    if [ $(( NOW_S - LAST_BEAT )) -ge "$HEARTBEAT" ]; then
        LAST_BEAT=$NOW_S
        log "heartbeat state=$STATE $REASON holder=$(holder_alive && echo up || echo down)"
    fi

    trim_log
    sleep "$POLL"
done
