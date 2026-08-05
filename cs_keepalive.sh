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
# ACTIVE  = a Claude Code process is running  AND  the newest *timestamped entry*
#           in any session transcript is younger than IDLE_WINDOW seconds.
#           Both must hold. Rationale for this signal over the alternatives:
#             - bare process/tmux-session existence: a Claude sitting at its
#               prompt for days would pin the box alive 24/7 and burn money.
#             - tmux #{window_activity}: unreliable here — every session on this
#               box reports "0s ago" because the TUI repaints, so it can never
#               distinguish working from idle.
#             - transcript FILE MTIME: this is what the script used until
#               2026-08-05 and it is actively wrong — see activity_age() for the
#               measurements. Claude Code rewrites quiet transcripts in place, so
#               mtime kept re-arming the grace window and the box never idled out.
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

HOLDER_PID=""
LAST_PAT_WARN=0
# Distinctive marker so we can find our own held sessions and nothing else.
HOLD_MARK="cs-keepalive-hold"

# If a previous supervisor was SIGKILLed (uncatchable, so the trap never ran),
# its ssh child survives as an orphan and would keep the box alive forever with
# nothing watching it.
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

# Is a *real* supervisor (another copy of this script) alive? Only an argv that
# actually ends in the script name counts — `pgrep -f` alone would also match a
# shell that merely mentions the path, e.g. someone grepping for it.
supervisor_alive() {
    local p argv
    for p in $(pgrep -f 'cs_keepalive\.sh' 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        argv=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)
        case "$argv" in *cs_keepalive.sh|*cs_keepalive.sh\ *) return 0 ;; esac
    done
    return 1
}

# Singleton — plus recovery from a lock wedged by a supervisor-less holder.
#
# THE BUG THIS RECOVERS FROM (fixed at source in start_holder, kept here for
# pre-fix orphans and for any future way a supervisor can die uncleanly):
# start_holder's subshell used to inherit fd 9, so a SIGKILLed supervisor left
# its ssh holder owning BOTH the flock AND a live client session. The codespace
# then stayed awake indefinitely with nothing watching it, and every replacement
# supervisor died silently right here — session-init.sh sees no supervisor, so
# it starts one, `flock -n` refuses, repeat forever. Nothing logged, because the
# old code exited before the first log line. Observed live on 2026-08-05: pids
# 13806/13808 held /tmp/.cs_keepalive.lock on fd 9 with no supervisor alive.
# A held session that no watchdog can ever release is exactly how this box ran
# for days at a stretch.
exec 9>"/tmp/.cs_keepalive.lock" 2>/dev/null || exit 0
if ! flock -n 9; then
    if supervisor_alive; then
        exit 0                      # a healthy sibling owns it — leave quietly
    fi
    reap_orphans                    # lock held by holders with nobody behind them
    # Wait rather than -n: short-lived children (the poll `sleep`) also inherit
    # fd 9, so a dead supervisor can leave the lock briefly held by a sleep that
    # is harmless and about to exit. No live supervisor exists at this point —
    # we just checked — so blocking here cannot deadlock against a real one.
    flock -w 90 9 || { log "lock still held after reaping orphans — exiting"; exit 0; }
    log "recovered a wedged lock (orphaned holder owned it, no supervisor alive)"
fi

log "keepalive starting (pid $$, codespace $CODESPACE_NAME, idle_window=${IDLE_WINDOW}s)"
reap_orphans

claude_running() {
    pgrep -f '(^|/)claude($| )' >/dev/null 2>&1 \
        || pgrep -f '\.local/bin/claude' >/dev/null 2>&1
}

# The real Claude CLI processes. `pgrep -x claude` matches comm == "claude"
# exactly, so it skips tmux, the launcher and this script. Verified on this box:
# comm really is "claude" and pgrep -x finds all live sessions. The node
# fallback catches an npm-installed CLI, whose comm is "node" — without it the
# busy signal silently reads zero.
claude_roots() {
    { pgrep -x claude 2>/dev/null
      for pid in $(pgrep -x node 2>/dev/null); do
          tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'claude' && echo "$pid"
      done
    } | sort -u
}

# Total CPU jiffies (utime+stime) across those roots AND every descendant.
#
# Descendants are counted deliberately: when Claude shells out to a long build
# the CPU is burned by the child while `claude` itself sits near-idle waiting on
# it. Summing the roots alone reads a running build as "not working", and with
# the transcript signal also quiet during a build (no entry is written until the
# tool returns) that would put the box to sleep mid-build.
#
# This cannot feed back into itself: the script runs as a child of init
# (verified on this box, ppid 1), never underneath a claude process, so neither
# its own polling nor the held ssh session lands in this sum.
claude_cpu() {
    local roots all frontier next total=0 pid stat
    roots=$(claude_roots)
    [ -n "$roots" ] || { echo 0; return; }
    all="$roots"; frontier="$roots"
    while [ -n "$frontier" ]; do
        next=$(ps -o pid= --ppid "$(echo $frontier | tr ' ' ',')" 2>/dev/null | tr -d ' ' | sort -u)
        [ -n "$next" ] || break
        next=$(comm -13 <(printf '%s\n' $all | sort -u) <(printf '%s\n' $next))
        [ -n "$next" ] || break
        all=$(printf '%s\n%s\n' "$all" "$next")
        frontier="$next"
    done
    for pid in $all; do
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
        stat=${stat##*) }            # strip "pid (comm) "; robust to parens in comm
        set -- $stat                 # after strip: utime=field 12, stime=field 13
        total=$(( total + ${12:-0} + ${13:-0} ))
    done
    echo "$total"
}

# Age in seconds of the newest genuine conversation activity across all session
# transcripts; 999999 when there is none.
#
# This deliberately does NOT trust the file mtime. Claude Code rewrites a
# transcript in place long after its session has gone quiet: metadata-only lines
# (last-prompt / ai-title / mode) and a periodic housekeeping pass both bump
# mtime without adding a word of conversation. Measured here on 2026-08-05, two
# transcripts carried mtimes 1h37m and 2h17m newer than their last timestamped
# entry, and one abandoned session was re-touched every ~22 min for six hours
# straight. Against a 15-minute window that produced a sawtooth — release,
# re-hold, release — so the 30-minute GitHub idle timeout never once ran to
# completion and the box stayed billable for days. In the logged week, 7 of the
# 31.6 held hours were bought by nothing but a rewritten mtime. Killing that is
# the entire reason this function reads entries instead of stat().
#
# mtime is still used as a cheap PRE-FILTER, which is sound in one direction
# only: a rewrite can only ever move mtime forward, so mtime is an upper bound
# on freshness and a file that already looks stale by mtime cannot be fresh by
# content. Whatever survives the filter is then read for real.
activity_age() {
    local mins now newest=0 f ts e
    mins=$(( (IDLE_WINDOW + 59) / 60 ))
    now=$(date +%s)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Transcripts reach tens of MB; only the tail can hold the last entry.
        ts=$(tail -c 262144 "$f" 2>/dev/null \
             | grep -o '"timestamp":"[0-9TZ:.+-]*"' | tail -n 1 | cut -d'"' -f4)
        if [ -z "$ts" ]; then
            e="$now"                 # unreadable tail — fail SAFE, treat as live
        else
            e=$(date -u -d "$ts" +%s 2>/dev/null) || e=0
        fi
        [ "${e:-0}" -gt "$newest" ] && newest=$e
    done < <(find "$HOME/.claude/projects" "$HOME/.claude/sessions" \
                  -name '*.jsonl' -mmin "-$mins" 2>/dev/null)
    if [ "$newest" -eq 0 ]; then echo 999999; else echo $(( now - newest )); fi
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
# actually thinking/streaming/running tools) and a grace window after the last
# real conversation entry, which bridges the gap while a tool call is in flight.
REASON=""
should_keep() {
    local delta="$1" age
    if [ -f "$FORCE_FLAG" ]; then REASON="forced(flag)"; return 0; fi
    if ! claude_running; then REASON="no-claude(cpu ${delta}j)"; return 1; fi
    if [ "$delta" -ge "$BUSY_JIFFIES" ]; then
        REASON="busy(cpu ${delta}j/${BUSY_JIFFIES}j)"; return 0
    fi
    age=$(activity_age)
    if [ "$age" -lt "$IDLE_WINDOW" ]; then
        REASON="recent(activity ${age}s<${IDLE_WINDOW}s,cpu ${delta}j)"; return 0
    fi
    REASON="idle(activity ${age}s>=${IDLE_WINDOW}s,cpu ${delta}j)"; return 1
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
        # Drop the singleton lock fd before exec'ing. Without this the holder
        # inherits fd 9 and therefore the flock, so if the supervisor is ever
        # SIGKILLed the surviving holder keeps BOTH the lock and the client
        # session: the box is pinned awake with no watchdog, and every
        # replacement supervisor is silently refused the lock forever. This one
        # line is the fix; the recovery path at the flock is the safety net.
        exec 9>&-
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
