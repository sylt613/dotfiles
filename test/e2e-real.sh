#!/bin/bash
# REAL end-to-end verification — no mocks. Downloads the actual VS Code
# server, lays it out exactly like a codespace's /vscode mount, runs
# install.sh in a clean HOME with a forced-clean PATH (so the real native
# Claude CLI installer runs), and asserts the watcher installs the REAL
# anthropic.claude-code extension from the real marketplace.
# Used by .github/workflows/verify.yml; can also be run anywhere with network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="${RUNNER_TEMP:-$(mktemp -d /tmp/e2e.XXXXXX)}/e2e-real"
rm -rf "$SB"
H="$SB/home"; VSROOT="$SB/vscode"
mkdir -p "$H" "$SB/ipc" "$VSROOT/bin/linux-x64"

echo "── downloading real VS Code server (stable, linux-x64)"
curl -fsSL --retry 3 -o "$SB/server.tgz" \
    "https://update.code.visualstudio.com/latest/server-linux-x64/stable"
tar -xzf "$SB/server.tgz" -C "$VSROOT/bin/linux-x64"
mv "$VSROOT/bin/linux-x64/vscode-server-linux-x64" "$VSROOT/bin/linux-x64/real"
test -x "$VSROOT/bin/linux-x64/real/bin/code-server"
echo "   server ready: $("$VSROOT/bin/linux-x64/real/bin/code-server" --version 2>/dev/null | head -1 || true)"

echo "── running install.sh in clean HOME (native CLI installer, real network)"
env -i HOME="$H" TERM=dumb SHELL=/bin/bash \
    PATH="/usr/bin:/bin:/usr/local/bin" \
    CODESPACES=true \
    DOTFILES_VSCODE_ROOT="$VSROOT" \
    DOTFILES_VSCODE_IPC_GLOB="$SB/ipc/*.sock" \
    DOTFILES_VSCODE_WAIT=300 DOTFILES_VSCODE_POLL=2 \
    CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-E2E-PLACEHOLDER" \
    bash "$ROOT/install.sh"

echo "── waiting for the extension watcher (real marketplace downloads)"
for _ in $(seq 1 150); do
    [ -f "$H/.dotfiles-state/extensions-ok" ] && break
    sleep 2
done
if [ ! -f "$H/.dotfiles-state/extensions-ok" ]; then
    echo "❌ watcher never finished; log:"; cat "$H/.dotfiles-vscode-setup.log" || true
    exit 1
fi
cat "$H/.dotfiles-vscode-setup.log"

echo "── assertions"
ls -d "$H"/.vscode-remote/extensions/anthropic.claude-code-*
test -x "$H/.local/bin/claude"
echo "   claude: $(env -i HOME="$H" PATH="$H/.local/bin:/usr/bin:/bin" claude --version 2>/dev/null | head -1)"
grep -q '"defaultMode": "bypassPermissions"' "$H/.claude/settings.json"
grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$H/.claude/settings.json"

echo "── ai-check must report READY"
env -i HOME="$H" TERM=dumb CODESPACES=true \
    PATH="$H/.local/bin:/usr/bin:/bin:/usr/local/bin" \
    bash "$H/.local/bin/ai-check"

echo "✅ REAL E2E PASSED — extension + CLI + auth wiring all real"
