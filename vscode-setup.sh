#!/bin/bash
# Installs VS Code extensions inside a codespace, waiting for the VS Code
# server to exist first. The plain `code` CLI does NOT exist while dotfiles
# run (codespace creation happens before the server / before a client ever
# attaches), which is why a naive `code --install-extension` in install.sh
# silently does nothing. This script runs in the background instead and:
#
#   1. waits for the VS Code server bits (mounted at /vscode in codespaces),
#      then installs headlessly via `code-server --install-extension` into the
#      server's extensions dir (~/.vscode-remote/extensions) — this works
#      BEFORE you ever open the codespace, so the extension is there on attach
#   2. falls back to the remote CLI + an IPC socket (available once a client
#      has attached) in case the server CLI route is unavailable
#
# Idempotent + singleton (flock). Re-launched by session-init.sh on new
# terminals until it succeeds. Log: ~/.dotfiles-vscode-setup.log

STATE_DIR="$HOME/.dotfiles-state"
mkdir -p "$STATE_DIR"
[ -f "$STATE_DIR/extensions-ok" ] && exit 0

exec 9>"$STATE_DIR/vscode-setup.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

exec >>"$HOME/.dotfiles-vscode-setup.log" 2>&1

# The Claude Code extension must be first — it's the one that matters most.
EXTENSIONS=(
    anthropic.claude-code
    github.vscode-pull-request-github
    ms-python.python
    wienans.opencode-zen-chat-provider
    calgan.oai-provider
)

# Overridable for tests.
VSROOT="${DOTFILES_VSCODE_ROOT:-/vscode}"
IPC_GLOB="${DOTFILES_VSCODE_IPC_GLOB:-/tmp/vscode-ipc-*.sock}"
WAIT="${DOTFILES_VSCODE_WAIT:-1800}"
POLL="${DOTFILES_VSCODE_POLL:-10}"

echo "── vscode-setup start $(date '+%F %T') (wait up to ${WAIT}s)"

ext_dir() {
    # Codespaces server keeps extensions in ~/.vscode-remote/extensions;
    # plain dev containers / SSH use ~/.vscode-server/extensions.
    if [ -d "$HOME/.vscode-remote" ] || [ -d "$VSROOT" ]; then
        echo "$HOME/.vscode-remote/extensions"
    elif [ -d "$HOME/.vscode-server" ]; then
        echo "$HOME/.vscode-server/extensions"
    else
        echo "$HOME/.vscode-remote/extensions"
    fi
}

find_server_cli() {
    local c
    for c in "$VSROOT"/bin/linux-x64/*/bin/code-server \
             "$VSROOT"/bin/*/bin/code-server \
             "$HOME"/.vscode-remote/bin/*/bin/code-server \
             "$HOME"/.vscode-server/bin/*/bin/code-server; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

find_remote_cli() {
    local c
    for c in "$VSROOT"/bin/linux-x64/*/bin/remote-cli/code \
             "$VSROOT"/bin/*/bin/remote-cli/code \
             "$HOME"/.vscode-remote/bin/*/bin/remote-cli/code \
             "$HOME"/.vscode-server/bin/*/bin/remote-cli/code; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

has_claude_ext() {  # "$@" = list command prefix
    "$@" --list-extensions 2>/dev/null | grep -qi '^anthropic\.claude-code$'
}

install_all() {  # "$@" = install command prefix
    local e
    for e in "${EXTENSIONS[@]}"; do
        if "$@" --install-extension "$e" --force >/dev/null 2>&1; then
            echo "  ✅ $e"
        else
            echo "  ⚠️ $e install failed"
        fi
    done
}

deadline=$(( $(date +%s) + WAIT ))
done_via=""
while [ -z "$done_via" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    # Route 1: headless install through the server CLI (no client needed).
    if cli=$(find_server_cli); then
        dir=$(ext_dir)
        mkdir -p "$dir"
        echo "server CLI: $cli → $dir"
        install_all "$cli" --extensions-dir "$dir"
        has_claude_ext "$cli" --extensions-dir "$dir" && done_via="server-cli"
    fi

    # Route 2: remote CLI through an IPC socket (exists once a client attached).
    if [ -z "$done_via" ] && rcli=$(find_remote_cli); then
        # shellcheck disable=SC2086  # IPC_GLOB must glob
        for sock in $(ls -t $IPC_GLOB 2>/dev/null); do
            if env VSCODE_IPC_HOOK_CLI="$sock" "$rcli" --list-extensions >/dev/null 2>&1; then
                echo "remote CLI via IPC: $sock"
                install_all env VSCODE_IPC_HOOK_CLI="$sock" "$rcli"
                has_claude_ext env VSCODE_IPC_HOOK_CLI="$sock" "$rcli" && done_via="remote-cli"
                break
            fi
        done
    fi

    [ -n "$done_via" ] || sleep "$POLL"
done

if [ -n "$done_via" ]; then
    touch "$STATE_DIR/extensions-ok"
    echo "✅ extensions installed via $done_via $(date '+%F %T')"
else
    echo "⚠️ VS Code server never became available within ${WAIT}s — will retry on next terminal"
fi
