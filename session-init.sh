#!/bin/bash
# Sourced from ~/.bashrc / ~/.zshrc on every shell — must stay fast and quiet.
# Self-heals the pieces that can't be guaranteed at codespace-creation time:
#   - auth seeding, if the secret only became visible after a restart
#   - extension install, if the VS Code server appeared after install.sh's
#     watcher gave up (or after a codespace stop/start)
#   - the keep-alive pinger, which dies with the container on stop/start
# All launched jobs are flock-singletons and marker-guarded, so this is a
# no-op (a few file tests) once everything is in place.

_ai_dir="${AI_DOTFILES_DIR:-}"
if [ -n "$_ai_dir" ] && { [ -n "${CODESPACES:-}" ] || [ -n "${CODESPACE_NAME:-}" ] || [ -n "${AI_DOTFILES_FORCE:-}" ]; }; then
    _ai_state="$HOME/.dotfiles-state"

    if [ ! -f "$_ai_state/auth-configured" ] \
       && { [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; } \
       && [ -f "$_ai_dir/claude-auth.sh" ]; then
        bash "$_ai_dir/claude-auth.sh" >>"$HOME/.dotfiles-install.log" 2>&1
    fi

    if [ ! -f "$_ai_state/extensions-ok" ] && [ -f "$_ai_dir/vscode-setup.sh" ] \
       && ! pgrep -f vscode-setup.sh >/dev/null 2>&1; then
        ( nohup bash "$_ai_dir/vscode-setup.sh" >/dev/null 2>&1 & ) 2>/dev/null
    fi

    if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GH_CODESPACE_PAT:-}" ] \
       && [ -f "$_ai_dir/cs_keepalive.sh" ] \
       && ! pgrep -f cs_keepalive >/dev/null 2>&1; then
        ( nohup bash "$_ai_dir/cs_keepalive.sh" >>/tmp/.cs_keepalive.log 2>&1 & ) 2>/dev/null
    fi

    # Re-create the persistent Claude tmux session if it's gone (stop/start
    # kills the in-memory tmux server). Skip when we're *inside* tmux already
    # (e.g. the session's own fallback shell) so this never self-triggers.
    if [ -z "${TMUX:-}" ] && [ -f "$_ai_dir/claude-tmux.sh" ] \
       && command -v tmux >/dev/null 2>&1 \
       && ! tmux has-session -t "${CLAUDE_TMUX_SESSION:-claude}" 2>/dev/null; then
        bash "$_ai_dir/claude-tmux.sh" >>"$HOME/.dotfiles-install.log" 2>&1
    fi
fi
unset _ai_dir _ai_state
