#!/bin/bash
# Sandbox test harness: simulates the Codespaces dotfiles flow end-to-end
# (fake HOME, fake /vscode server tree, mock CLIs) and asserts the setup
# actually produces a logged-in, extension-installed, full-auto environment.
# Run: bash test/run-tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; CURRENT=""

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "    ✅ $*"; }
bad()  { FAIL=$((FAIL+1)); say "    ❌ [$CURRENT] $*"; }

assert_file()  { [ -f "$1" ] && ok "file exists: ${1#"$HOME"/}" || bad "missing file: $1"; }
assert_dir()   { [ -d "$1" ] && ok "dir exists: ${1#"$HOME"/}" || bad "missing dir: $1"; }
assert_nofile(){ [ ! -f "$1" ] && ok "absent as expected: ${1#"$HOME"/}" || bad "should not exist: $1"; }
assert_grep()  { grep -q "$2" "$1" 2>/dev/null && ok "$3" || bad "$3 — pattern '$2' not in $1"; }
assert_nogrep(){ if grep -q "$2" "$1" 2>/dev/null; then bad "$3 — pattern '$2' FOUND in $1"; else ok "$3"; fi; }
assert_same()  { cmp -s "$1" "$2" && ok "$3" || bad "$3 — files differ"; }
assert_mode()  { [ "$(stat -c %a "$1" 2>/dev/null)" = "$2" ] && ok "perms $2 on ${1#"$HOME"/}" || bad "perms on $1 = $(stat -c %a "$1" 2>/dev/null), want $2"; }

wait_for_file() { # path seconds
    local i=0
    while [ ! -e "$1" ] && [ "$i" -lt "${2:-30}" ]; do sleep 1; i=$((i+1)); done
    [ -e "$1" ]
}

CREDS_JSON='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-TESTTOKEN","refreshToken":"sk-ant-ort01-TESTREFRESH","expiresAt":4102444800000,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}'

# ── mocks ────────────────────────────────────────────────────────────────────
make_mocks() { # $1 = mocks dir
    mkdir -p "$1"
    cat > "$1/claude" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--version" ] && echo "2.1.0 (Claude Code)"
exit 0
EOF
    cat > "$1/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
    cat > "$1/npm" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$1/curl" <<'EOF'
#!/bin/bash
exit 22
EOF
    # stateful tmux mock: tracks sessions in $HOME and logs every call so tests
    # can assert what claude-tmux.sh did (created a session, in bypass mode, etc).
    cat > "$1/tmux" <<'EOF'
#!/bin/bash
ST="$HOME/.tmux-mock-sessions"; LOG="$HOME/.tmux-mock.log"
printf '%s\n' "$*" >> "$LOG"
sub="${1:-}"; shift 2>/dev/null
name=""; prev=""
for a in "$@"; do
    case "$prev" in -t|-s) name="$a" ;; esac
    prev="$a"
done
case "$sub" in
    has-session)     grep -qxF "$name" "$ST" 2>/dev/null && exit 0 || exit 1 ;;
    new-session)     [ -n "$name" ] && { grep -qxF "$name" "$ST" 2>/dev/null || printf '%s\n' "$name" >> "$ST"; }; exit 0 ;;
    display-message) echo 0; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$1"/*
}

# mock code-server: records calls, "installs" by creating ext dirs, lists them
make_code_server() { # $1 = target path
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
#!/bin/bash
EXTDIR="$HOME/.vscode-remote/extensions"; MODE=""; EXT=""
echo "$*" >> "$(dirname "$0")/calls.log"
while [ $# -gt 0 ]; do
    case "$1" in
        --extensions-dir) EXTDIR="$2"; shift 2 ;;
        --install-extension) EXT="$2"; MODE=install; shift 2 ;;
        --list-extensions) MODE=list; shift ;;
        *) shift ;;
    esac
done
if [ "$MODE" = install ]; then mkdir -p "$EXTDIR/${EXT}-1.0.0"; fi
if [ "$MODE" = list ]; then
    for d in "$EXTDIR"/*/; do b=$(basename "$d"); [ "$b" != "*" ] && echo "${b%-*}"; done
fi
exit 0
EOF
    chmod +x "$1"
}

# mock remote-cli code: requires VSCODE_IPC_HOOK_CLI pointing at existing sock
make_remote_cli() { # $1 = target path
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
#!/bin/bash
[ -n "${VSCODE_IPC_HOOK_CLI:-}" ] && [ -e "$VSCODE_IPC_HOOK_CLI" ] || exit 1
EXTDIR="$HOME/.vscode-remote/extensions"; MODE=""; EXT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install-extension) EXT="$2"; MODE=install; shift 2 ;;
        --list-extensions) MODE=list; shift ;;
        *) shift ;;
    esac
done
if [ "$MODE" = install ]; then mkdir -p "$EXTDIR/${EXT}-1.0.0"; fi
if [ "$MODE" = list ]; then
    for d in "$EXTDIR"/*/; do b=$(basename "$d"); [ "$b" != "*" ] && echo "${b%-*}"; done
fi
exit 0
EOF
    chmod +x "$1"
}

# ── scenario scaffolding ─────────────────────────────────────────────────────
new_sandbox() { # sets SB, H, MOCKS, VSROOT, IPCDIR
    SB=$(mktemp -d /tmp/dotfiles-test.XXXXXX)
    H="$SB/home"; MOCKS="$SB/mocks"; VSROOT="$SB/vscode"; IPCDIR="$SB/ipc"
    mkdir -p "$H" "$IPCDIR"
    make_mocks "$MOCKS"
}

run_install() { # extra env as args, e.g. CLAUDE_CODE_OAUTH_TOKEN=x
    env -i HOME="$H" TERM=dumb SHELL=/bin/bash \
        PATH="$MOCKS:/usr/local/bin:/usr/bin:/bin" \
        CODESPACES=true \
        DOTFILES_VSCODE_ROOT="$VSROOT" \
        DOTFILES_VSCODE_IPC_GLOB="$IPCDIR/vscode-ipc-*.sock" \
        DOTFILES_VSCODE_WAIT="${TEST_WAIT:-20}" DOTFILES_VSCODE_POLL=1 \
        "$@" \
        bash "$ROOT/install.sh" >"$SB/install-stdout.log" 2>&1
}

# ── 0. syntax ────────────────────────────────────────────────────────────────
CURRENT="syntax"
say "▶ $CURRENT"
for f in "$ROOT"/install.sh "$ROOT"/claude-auth.sh "$ROOT"/vscode-setup.sh \
         "$ROOT"/cs_keepalive.sh "$ROOT"/claude-tmux.sh "$ROOT"/session-init.sh \
         "$ROOT"/ai-check "$ROOT"/test/run-tests.sh; do
    bash -n "$f" && ok "bash -n $(basename "$f")" || bad "syntax error in $f"
done

# ── 1. full install: base64 creds + fireworks key + server present ───────────
CURRENT="full-install-base64"
say "▶ $CURRENT"
new_sandbox
make_code_server "$VSROOT/bin/linux-x64/test-commit/bin/code-server"
B64=$(printf '%s' "$CREDS_JSON" | base64 -w0)
run_install CLAUDE_CREDENTIALS_JSON="$B64" FIREWORKS_API_KEY=fw-test \
    && ok "install.sh exit 0" || bad "install.sh exited non-zero"

assert_file "$H/.claude/.credentials.json"
assert_mode "$H/.claude/.credentials.json" 600
assert_grep "$H/.claude/.credentials.json" "sk-ant-oat01-TESTTOKEN" "credentials seeded from base64 secret"
assert_grep "$H/.claude/settings.json" '"defaultMode": "bypassPermissions"' "auto mode set"
assert_grep "$H/.claude.json" '"hasCompletedOnboarding": true' "onboarding pre-accepted"
assert_grep "$H/.claude.json" '"bypassPermissionsModeAccepted": true' "bypass confirmation pre-accepted"
assert_grep "$H/.vscode-remote/data/Machine/settings.json" "kimi" "provider config written"
assert_file "$H/.dotfiles-state/auth-configured"
assert_grep "$H/.bashrc" "ai-dotfiles" "bashrc hook installed"
assert_grep "$H/.bashrc" "claude-tui" "claude-tui attach helper installed"
assert_file "$H/.local/bin/ai-check"

# Claude auto-started in a persistent tmux session, in full-auto mode
assert_file "$H/.tmux-mock.log"
assert_grep "$H/.tmux-mock.log" "new-session" "claude tmux session created at install"
assert_grep "$H/.tmux-mock.log" "permission-mode bypassPermissions" "tmux launches claude in full-auto mode"
assert_grep "$H/.tmux-mock-sessions" "^claude$" "claude tmux session registered"
assert_grep "$H/.claude.json" "hasTrustDialogAccepted" "workspace folder pre-trusted (skips Claude's trust dialog)"

if wait_for_file "$H/.dotfiles-state/extensions-ok" 25; then
    ok "extension watcher finished"
    assert_dir "$H/.vscode-remote/extensions/anthropic.claude-code-1.0.0"
    assert_grep "$VSROOT/bin/linux-x64/test-commit/bin/calls.log" "anthropic.claude-code" "code-server asked to install claude extension"
else
    bad "extensions-ok marker never appeared (see $H/.dotfiles-vscode-setup.log)"
fi

# ai-check should report READY inside the sandbox
if env -i HOME="$H" TERM=dumb PATH="$MOCKS:/usr/local/bin:/usr/bin:/bin" \
    bash "$H/.local/bin/ai-check" >"$SB/ai-check.log" 2>&1; then
    ok "ai-check reports READY"
else
    bad "ai-check reports NOT READY: $(tail -3 "$SB/ai-check.log" | tr '\n' ' ')"
fi

# idempotency: run again, hook must appear exactly once
CURRENT="idempotent-rerun"
say "▶ $CURRENT"
run_install CLAUDE_CREDENTIALS_JSON="$B64" FIREWORKS_API_KEY=fw-test \
    && ok "second run exit 0" || bad "second run failed"
n=$(grep -c '# >>> ai-dotfiles >>>' "$H/.bashrc")
[ "$n" = "1" ] && ok "bashrc hook present exactly once" || bad "bashrc hook duplicated ($n times)"
# tmux session must NOT be re-created on a rerun (has-session guard holds)
m=$(grep -c 'permission-mode bypassPermissions' "$H/.tmux-mock.log")
[ "$m" = "1" ] && ok "tmux session created once across reruns (idempotent)" || bad "tmux new-session ran $m times, want 1"

# ── 2. raw (non-base64) credentials secret ───────────────────────────────────
CURRENT="raw-json-creds"
say "▶ $CURRENT"
new_sandbox
TEST_WAIT=3 run_install CLAUDE_CREDENTIALS_JSON="$CREDS_JSON"
assert_grep "$H/.claude/.credentials.json" "sk-ant-oat01-TESTTOKEN" "raw JSON secret accepted"

# ── 3. token-only secret ─────────────────────────────────────────────────────
CURRENT="token-only"
say "▶ $CURRENT"
new_sandbox
TEST_WAIT=3 run_install CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-ENVTOKEN"
assert_nofile "$H/.claude/.credentials.json"
assert_grep "$H/.claude/settings.json" '"CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-ENVTOKEN"' "token wired into settings env"
assert_mode "$H/.claude/settings.json" 600
assert_file "$H/.dotfiles-state/auth-configured"

# ── 4. no secrets at all: must still finish cleanly with warnings ────────────
CURRENT="no-secrets"
say "▶ $CURRENT"
new_sandbox
TEST_WAIT=3 run_install && ok "exit 0 with no secrets" || bad "install failed without secrets"
assert_grep "$H/.dotfiles-install.log" "No Claude auth found" "warning logged"
assert_nofile "$H/.dotfiles-state/auth-configured"

# ── 5. server appears LATE (real codespaces ordering) ────────────────────────
CURRENT="late-server"
say "▶ $CURRENT"
new_sandbox
( sleep 4; make_code_server "$VSROOT/bin/linux-x64/late-commit/bin/code-server" ) &
LATE_PID=$!
run_install CLAUDE_CODE_OAUTH_TOKEN="tok"
if wait_for_file "$H/.dotfiles-state/extensions-ok" 25; then
    ok "watcher waited for late server and installed"
else
    bad "watcher never caught the late server"
fi
wait "$LATE_PID" 2>/dev/null

# ── 6. IPC fallback (no code-server, client attached) ────────────────────────
CURRENT="ipc-fallback"
say "▶ $CURRENT"
new_sandbox
make_remote_cli "$VSROOT/bin/linux-x64/test-commit/bin/remote-cli/code"
touch "$IPCDIR/vscode-ipc-1234.sock"
run_install CLAUDE_CODE_OAUTH_TOKEN="tok"
if wait_for_file "$H/.dotfiles-state/extensions-ok" 25; then
    ok "extension installed via remote-cli + IPC socket"
    assert_dir "$H/.vscode-remote/extensions/anthropic.claude-code-1.0.0"
else
    bad "IPC fallback did not install"
fi

# ── 7. session-init self-heal (secret appears after creation) ────────────────
CURRENT="session-init-heal"
say "▶ $CURRENT"
# clear lingering watchers so session-init's pgrep guard can't misfire
i=0
while pgrep -f "$ROOT/vscode-setup.sh" >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
    pkill -f "$ROOT/vscode-setup.sh" 2>/dev/null
    sleep 1; i=$((i+1))
done
new_sandbox
make_code_server "$VSROOT/bin/linux-x64/test-commit/bin/code-server"
env -i HOME="$H" TERM=dumb PATH="$MOCKS:/usr/local/bin:/usr/bin:/bin" \
    AI_DOTFILES_DIR="$ROOT" AI_DOTFILES_FORCE=1 \
    CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-LATESECRET" \
    DOTFILES_VSCODE_ROOT="$VSROOT" \
    DOTFILES_VSCODE_IPC_GLOB="$IPCDIR/vscode-ipc-*.sock" \
    DOTFILES_VSCODE_WAIT=10 DOTFILES_VSCODE_POLL=1 \
    bash -c ". '$ROOT/session-init.sh'"
assert_grep "$H/.claude/settings.json" "sk-ant-oat01-LATESECRET" "session-init seeded auth post-hoc"
assert_grep "$H/.tmux-mock-sessions" "^claude$" "session-init re-created the Claude tmux session"
if wait_for_file "$H/.dotfiles-state/extensions-ok" 15; then
    ok "session-init launched extension watcher"
else
    bad "session-init did not get extension installed"
fi

# ── 8. corrupt existing state must NEVER be clobbered ────────────────────────
CURRENT="corrupt-state-preserved"
say "▶ $CURRENT"
new_sandbox
mkdir -p "$H/.claude"
printf '{"oauthAccount": {"email": "user@example.com", "trunc' > "$H/.claude.json"
printf '{"permissions": {"defaultMode": "bypassPermissions", ' > "$H/.claude/settings.json"
cp "$H/.claude.json" "$SB/claude.json.orig"
cp "$H/.claude/settings.json" "$SB/settings.json.orig"
TEST_WAIT=3 run_install CLAUDE_CODE_OAUTH_TOKEN="tok" \
    && ok "exit 0 despite corrupt state files" || bad "install failed on corrupt state"
assert_same "$H/.claude.json" "$SB/claude.json.orig" "~/.claude.json left byte-identical"
assert_same "$H/.claude/settings.json" "$SB/settings.json.orig" "settings.json left byte-identical"
assert_grep "$H/.dotfiles-install.log" "LEFT UNTOUCHED" "non-clobber warning logged"

# ── 8b. DEAD creds + valid token: dead creds must NOT shadow the token ───────
# The credentials file outranks CLAUDE_CODE_OAUTH_TOKEN in Claude's auth
# order, and a rotated-out snapshot can never refresh — seeding it would give
# every new codespace a login screen despite a perfectly valid 1-year token.
CURRENT="dead-creds-not-seeded"
say "▶ $CURRENT"
new_sandbox
DEAD_CREDS='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-DEADTOKEN","refreshToken":"sk-ant-ort01-ROTTED","expiresAt":1000000000000,"scopes":["user:inference"],"subscriptionType":"max"}}'
TEST_WAIT=3 run_install CLAUDE_CREDENTIALS_JSON="$DEAD_CREDS" CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-FRESH"
assert_nofile "$H/.claude/.credentials.json"
assert_grep "$H/.claude/settings.json" "sk-ant-oat01-FRESH" "valid token pinned, not shadowed"
assert_grep "$H/.dotfiles-install.log" "NOT seeding" "shadow-prevention logged"
# …and if a previous (older) run already seeded the dead snapshot, a re-run
# must remove it so the token takes over.
printf '%s' "$DEAD_CREDS" > "$H/.claude/.credentials.json"
TEST_WAIT=3 run_install CLAUDE_CREDENTIALS_JSON="$DEAD_CREDS" CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-FRESH"
assert_nofile "$H/.claude/.credentials.json"

# ── 9. creds + token together: both live — creds seeded AND token pinned ─────
# (refresh tokens are single-use; the static setup-token in settings env is the
# rotation-proof fallback if the credentials family dies)
CURRENT="creds-and-token"
say "▶ $CURRENT"
new_sandbox
TEST_WAIT=3 run_install CLAUDE_CREDENTIALS_JSON="$CREDS_JSON" CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-STALE"
assert_grep "$H/.claude/.credentials.json" "sk-ant-oat01-TESTTOKEN" "credentials file seeded"
assert_grep "$H/.claude/settings.json" "sk-ant-oat01-STALE" "static token pinned as fallback alongside creds"
assert_file "$H/.dotfiles-state/auth-configured"

# ── 10. claude-tmux is a no-op when a session is already running ─────────────
CURRENT="tmux-noop-when-running"
say "▶ $CURRENT"
new_sandbox
printf 'claude\n' > "$H/.tmux-mock-sessions"   # pretend a session is already up
env -i HOME="$H" TERM=dumb PATH="$MOCKS:/usr/local/bin:/usr/bin:/bin" \
    bash "$ROOT/claude-tmux.sh" >"$SB/ctmux.log" 2>&1
assert_grep "$SB/ctmux.log" "already running" "claude-tmux no-ops when the session exists"
assert_nogrep "$H/.tmux-mock.log" "new-session" "no second tmux session spawned"

# ── 11. claude-tmux still exits 0 (best-effort) when tmux is unavailable ──────
# Use a minimal PATH so no real system tmux leaks in (the test host may have it);
# the marker disables the apt path, so the missing-tmux branch needs only mkdir.
CURRENT="tmux-missing-graceful"
say "▶ $CURRENT"
new_sandbox
mkdir -p "$H/.dotfiles-state" "$SB/nobin"
touch "$H/.dotfiles-state/tmux-install-tried"   # sandbox OFF the real apt-get path
ln -sf "$(command -v mkdir)" "$SB/nobin/mkdir"
env -i HOME="$H" PATH="$SB/nobin" /bin/bash "$ROOT/claude-tmux.sh" >"$SB/ctmux2.log" 2>&1 \
    && ok "claude-tmux exits 0 without tmux" || bad "claude-tmux failed when tmux missing"
assert_grep "$SB/ctmux2.log" "tmux not available" "logs a clear skip message when tmux missing"

# ── summary ──────────────────────────────────────────────────────────────────
pkill -f "$ROOT/vscode-setup.sh" 2>/dev/null
echo
echo "════════════════════════════════════"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "✅ ALL TESTS PASSED"; exit 0; else echo "❌ FAILURES"; exit 1; fi
