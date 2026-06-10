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
         "$ROOT"/cs_keepalive.sh "$ROOT"/session-init.sh "$ROOT"/ai-check \
         "$ROOT"/test/run-tests.sh; do
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
assert_file "$H/.local/bin/ai-check"

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
pkill -f "$ROOT/vscode-setup.sh" 2>/dev/null; sleep 1   # clear any lingering watchers so pgrep guard can't misfire
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
if wait_for_file "$H/.dotfiles-state/extensions-ok" 15; then
    ok "session-init launched extension watcher"
else
    bad "session-init did not get extension installed"
fi

# ── summary ──────────────────────────────────────────────────────────────────
pkill -f "$ROOT/vscode-setup.sh" 2>/dev/null
echo
echo "════════════════════════════════════"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "✅ ALL TESTS PASSED"; exit 0; else echo "❌ FAILURES"; exit 1; fi
