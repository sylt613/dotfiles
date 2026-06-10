# dotfiles — AI coding codespaces

Every new codespace comes up with the **Claude Code VS Code extension installed
and already logged in**, in full-auto (`bypassPermissions`) mode, plus the
Claude CLI, provider config, git/gh auth, and a smart keep-alive.

## One-time setup (required — the scripts can't do this for you)

1. **Enable dotfiles**: [github.com/settings/codespaces](https://github.com/settings/codespaces)
   → check **"Automatically install dotfiles"** → select `sylt613/dotfiles`.
2. **Add secrets** using the one-command script (run on your laptop, not inside a
   codespace):

   ```bash
   git clone https://github.com/sylt613/dotfiles && cd dotfiles
   bash setup-secrets.sh
   ```

   This uploads your Claude login and grants it to all your current repos.
   Manual secret table for reference:

   | Secret | What | How to get it |
   |---|---|---|
   | `CLAUDE_CODE_OAUTH_TOKEN` | long-lived login token (easiest) | run `claude setup-token` on any logged-in machine, paste the `sk-ant-oat01-…` value |
   | `CLAUDE_CREDENTIALS_JSON` | full credentials incl. refresh token (alternative/extra) | `base64 -w0 ~/.claude/.credentials.json` on a logged-in Linux machine (raw JSON also accepted) |
   | `GH_CODESPACE_PAT` | optional: full-scope PAT for keep-alive + git/gh on private repos | github.com/settings/tokens (classic, `repo` + `codespace` scopes) |
   | `FIREWORKS_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | optional: OAI-provider extension models | provider dashboards |

   > **New repo?** GitHub user secrets can only be granted to specific repos (no
   > "all repos" option for user secrets). Run this any time you create a new repo:
   > ```bash
   > bash setup-secrets.sh --grant
   > ```

3. Dotfiles only apply to codespaces **created after** this — create a fresh
   codespace (or run *Codespaces: Rebuild Container*) to pick up changes.
   Changed/added secrets need a codespace **restart** to become visible.

## Verify

Open a terminal in the new codespace and run:

```
ai-check
```

It checks the CLI, auth, permission mode, the extension, and visible secrets,
and prints `✅ READY` or tells you exactly what's missing. The extension
installs in the background — if you attach very fast it can lag the first
attach by a few seconds; it retries automatically until it lands.

## How it works (and why the old version failed)

The `code` CLI **does not exist** while dotfiles run — codespace creation
happens before the VS Code server is up — so the old
`code --install-extension` always failed silently. Now:

- `install.sh` — entrypoint GitHub runs at creation. Never aborts halfway;
  logs to `~/.dotfiles-install.log`.
- `claude-auth.sh` — seeds `~/.claude/.credentials.json` from
  `CLAUDE_CREDENTIALS_JSON` (raw **or** base64) and/or wires
  `CLAUDE_CODE_OAUTH_TOKEN` into `~/.claude/settings.json → env`, which both
  the CLI **and the extension** read regardless of process environment.
- `vscode-setup.sh` — background watcher that waits (up to 30 min) for the VS
  Code server, then installs extensions headlessly via the server's
  `code-server` CLI into `~/.vscode-remote/extensions` (works before you even
  attach), with a remote-CLI + IPC-socket fallback. Log:
  `~/.dotfiles-vscode-setup.log`.
- `session-init.sh` — hooked into `~/.bashrc`; on every shell it re-seeds
  auth, re-launches the extension watcher, and restarts the keep-alive if any
  of them are missing (e.g. after a codespace stop/start or a late-granted
  secret). Marker files in `~/.dotfiles-state/` keep it a no-op once done.
- `cs_keepalive.sh` — idle timeout 240 min while Claude is actively writing
  session files, 15 min otherwise (needs `GH_CODESPACE_PAT`).
- `ai-check` — the verifier above.
- `test/run-tests.sh` — sandbox harness that simulates the whole codespace
  flow (fake HOME, fake `/vscode`, mock CLIs); run it after changing anything.

## Even more reliable: per-repo devcontainer (+ optional prebuild)

Dotfiles are account-wide but install the extension *after* creation. For
repos you use a lot, copy
[`devcontainer-template/devcontainer.json`](devcontainer-template/devcontainer.json)
to `<repo>/.devcontainer/devcontainer.json` — then **GitHub itself** installs
the extensions during creation, and the template's `postCreateCommand` runs
this repo's bootstrap directly, so the full setup (login, auto-mode,
keep-alive) works **even if the dotfiles toggle is off**. Enabling a
**prebuild** (repo → Settings → Codespaces → *Set up prebuild*) bakes the
extensions in so codespaces start instantly.

Prebuilds **cannot** handle login: user secrets don't exist at prebuild time,
and anything written into a prebuild snapshot is stored and shared — never
bake tokens in. Login, auto-mode, and keep-alive stay with these dotfiles
(they run at create time and compose fine with prebuilds).

## Recovery (if a codespace's Claude config ever breaks)

Rebuilding a codespace wipes `$HOME` (GitHub behavior) — config comes back
only if dotfiles run again. To restore by hand inside a codespace:

```bash
cp ~/.claude.json.backup ~/.claude.json    # Claude keeps this backup itself
bash /workspaces/.codespaces/.persistedshare/dotfiles/install.sh   # re-run setup
ai-check                                   # confirm
```

## Troubleshooting

- `~/.dotfiles-install.log` — main setup log
- `~/.dotfiles-vscode-setup.log` — extension installer log
- `/workspaces/.codespaces/.persistedshare/creation.log` — GitHub's creation log
- `printenv | grep -E 'CLAUDE|GH_'` — confirms which secrets reached the
  codespace (empty ⇒ secret not granted to this repo, or needs a restart)
