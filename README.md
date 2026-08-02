# dotfiles — AI coding codespaces

Every new codespace comes up with the **Claude Code VS Code extension installed
and already logged in**, in full-auto (`bypassPermissions`) mode, plus the
Claude CLI, provider config, git/gh auth, and a smart keep-alive — **and a
full-auto Claude TUI already running in a detached `tmux` session** so a task
keeps going after you close the tab. Attach any time with `claude-tui`.

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
   | `CLAUDE_CODE_OAUTH_TOKEN` | **THE auth** — static login token, valid ~1 year, immune to refresh-token rotation | run `claude setup-token` on any logged-in machine (laptop or working codespace), paste the `sk-ant-oat01-…` value |
   | `CLAUDE_CREDENTIALS_JSON` | ⚠️ opt-in only (`setup-secrets.sh --with-creds`) — a snapshot that **dies** as soon as any Claude install rotates the refresh token, and a dead one used to block login entirely. Don't use unless you know why you need it | `base64 -w0 ~/.claude/.credentials.json` |
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

It checks the CLI, auth, permission mode, the extension, the Claude tmux
session, and visible secrets, and prints `✅ READY` or tells you exactly what's
missing. The extension installs in the background — if you attach very fast it
can lag the first attach by a few seconds; it retries automatically until it
lands.

## Always-on Claude in tmux (kick off a task, close the tab, come back later)

The setup starts Claude Code in full-auto mode inside a **detached tmux
session** at codespace creation, so it keeps running even when no editor/browser
is attached. To use it:

```bash
claude-tui            # attach to the running full-auto Claude session
#  …work with Claude…
# Ctrl-b then d        → detach (Claude keeps running in the background)
```

- It opens **straight to the prompt in `bypassPermissions` mode** — no trust
  dialog, no bypass-warning, no permission prompts (workspace pre-trusted, mode
  set explicitly, and `skipDangerousModePermissionPrompt` set).
- **Default model is Opus** (switch per session with `/model`). **Fable** is
  enabled on the account too, but isn't in the `/model` picker — run
  `claude-fable` (or `claude --model fable`) for a quick Fable session.
- If you `/exit` or it crashes, the session drops to a shell and `claude-tui`
  restarts it (idempotent). After a codespace **stop/start** the first terminal
  re-creates it automatically.
- **Smart keep-alive ties into this:** while that Claude is actively working
  (writing a transcript, or its tmux pane is printing) the codespace idle
  timeout is raised to **240 min** so long autonomous runs aren't killed; when
  it goes quiet (idle at the prompt) it drops back to **15 min** so the machine
  stops promptly and you don't pay for an idle box. Needs `GH_CODESPACE_PAT`.

> Prefer a different session name? Set `CLAUDE_TMUX_SESSION`. Don't want it at
> all? It's best-effort — if tmux can't be installed it just skips, and the VS
> Code extension still works normally.

## How it works (and why the old version failed)

The `code` CLI **does not exist** while dotfiles run — codespace creation
happens before the VS Code server is up — so the old
`code --install-extension` always failed silently. Now:

- `install.sh` — entrypoint GitHub runs at creation. Never aborts halfway;
  logs to `~/.dotfiles-install.log`.
- `claude-auth.sh` — wires `CLAUDE_CODE_OAUTH_TOKEN` into
  `~/.claude/settings.json → env`, which both the CLI **and the extension**
  read regardless of process environment. Also seeds
  `~/.claude/.credentials.json` from `CLAUDE_CREDENTIALS_JSON` (raw or base64)
  — but **never when those credentials are expired and a token exists**: the
  credentials file outranks the token in Claude's auth order, so a dead
  snapshot would shadow a perfectly valid token (this exact bug caused the
  "401 / login screen despite a valid 1-year token" failures).
- `vscode-setup.sh` — background watcher that waits (up to 30 min) for the VS
  Code server, then installs extensions headlessly via the server's
  `code-server` CLI into `~/.vscode-remote/extensions` (works before you even
  attach), with a remote-CLI + IPC-socket fallback. Log:
  `~/.dotfiles-vscode-setup.log`.
- `session-init.sh` — hooked into `~/.bashrc`; on every shell it re-seeds
  auth, re-launches the extension watcher, restarts the keep-alive, and
  re-creates the Claude tmux session if any are missing (e.g. after a codespace
  stop/start or a late-granted secret). Marker files in `~/.dotfiles-state/`
  keep it a no-op once done.
- `claude-tmux.sh` — starts the detached full-auto Claude TUI (`claude-tui` to
  attach). Installs tmux if the image lacks it, pre-trusts the workspace folder
  and launches with `--permission-mode bypassPermissions` so it opens with no
  dialogs, and is idempotent (no-op if the session already exists).
- `cs_keepalive.sh` — idle timeout 240 min while Claude is working (a transcript
  write **or** recent output in the Claude tmux pane), 15 min otherwise (needs
  `GH_CODESPACE_PAT`).
- `ai-check` — the verifier above.
- `test/run-tests.sh` — sandbox harness that simulates the whole codespace
  flow (fake HOME, fake `/vscode`, mock CLIs); run it after changing anything.

## GitHub workflows in this repo

- `verify` — runs both test suites on every push to main. Should always be
  green; a red run means a script regression.
- `codespace-e2e` — **the definitive canary** (manual: Actions tab → run, or
  `gh workflow run codespace-e2e.yml`). Creates a REAL codespace on this repo,
  verifies dotfiles ran, ai-check is READY, the extension installed, the
  full-auto Claude **tmux** session came up at a clean prompt, and that a real
  `claude -p` conversation round-trips with your secrets — then deletes the
  codespace. Green = the whole system works for real. Needs the
  `GH_PAT_SECRETS` Actions secret (classic PAT, repo + codespace scopes).
- `grant-secrets` — daily 06:00 UTC + manual. Grants every Codespace secret to
  all your repos. Needs a classic PAT (repo + codespace scopes) in the
  `GRANT_PAT` (or `GH_PAT_SECRETS`) **Actions** secret of this repo; without
  one it no-ops cleanly instead of failing.
- `claude-oauth-refresh` — **manual-only, on purpose.** Anthropic refresh
  tokens are single-use: any Claude install that refreshes rotates the token
  and invalidates every stored copy, so a scheduled refresh is guaranteed to
  decay into permanent `invalid_grant` failures (which is exactly what the old
  cron did). Dispatch it only right after seeding fresh credentials into this
  repo's `CLAUDE_CREDENTIALS_JSON` Actions secret. The reliable everyday auth
  is the static `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`, valid ~1
  year, immune to rotation) — credentials JSON is the optional extra, not the
  foundation.

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

## Housekeeping (the complete maintenance runbook)

| When | What to do |
|---|---|
| **~once a year** (token expires) | `claude setup-token` anywhere logged-in → `bash setup-secrets.sh` → done. Optionally run the `codespace-e2e` workflow to confirm. |
| **created a new repo** | `bash setup-secrets.sh --grant` (or dispatch the `grant-secrets` workflow; it also runs daily at 06:00 UTC if `GRANT_PAT`/`GH_PAT_SECRETS` is set). User secrets can't be granted to "all future repos" — GitHub limitation. |
| **codespace shows a login screen** | `rm -f ~/.claude/.credentials.json` inside it, restart Claude — a dead credentials file was shadowing the token (old dotfiles clone). New codespaces are immune. |
| **want proof everything works** | Actions tab → `codespace-e2e` → Run workflow. Green = extension + auth + real conversation verified in a real codespace. |
| **rotated/revoked the token** | same as the yearly step: mint + `setup-secrets.sh`. |
| **never** | do NOT schedule `claude-oauth-refresh`, and do NOT upload credentials snapshots unless you know why (`--with-creds`) — both decay by design (single-use refresh tokens). |

## Recovery (if a codespace's Claude config ever breaks)

Rebuilding a codespace wipes `$HOME` (GitHub behavior) — config comes back
only if dotfiles run again. To restore by hand inside a codespace:

```bash
cp ~/.claude.json.backup ~/.claude.json    # Claude keeps this backup itself
bash /workspaces/.codespaces/.persistedshare/dotfiles/install.sh   # re-run setup
rm -f ~/.claude/.credentials.json          # if STILL logged out: kill a shadowing dead credentials file
ai-check                                   # confirm
```

## Troubleshooting

- `~/.dotfiles-install.log` — main setup log
- `~/.dotfiles-vscode-setup.log` — extension installer log
- `/workspaces/.codespaces/.persistedshare/creation.log` — GitHub's creation log
- `printenv | grep -E 'CLAUDE|GH_'` — confirms which secrets reached the
  codespace (empty ⇒ secret not granted to this repo, or needs a restart)

### The `/model` picker won't offer Fable (or shows "Usage Credits")

Not a billing problem, and not the stale-tier bug from the upstream issue.
Token auth (`claude setup-token`) has no account record attached, so
`oauthAccount` in `~/.claude.json` stays `null`, the picker can't see your plan,
and it gates Fable. Nothing errors — inference works and `claude -p --model
fable` even runs real Fable; only the picker is wrong.

```bash
ai-check                     # "Plan entitlement" section says if you're hit
claude-relogin.sh            # prepares the box
env -u CLAUDE_CODE_OAUTH_TOKEN claude   # then: /login  (reload the VS Code window after)
claude-relogin.sh --save     # publish the fresh credential to every repo
```

Only an interactive `/login` mints the account record — no script can do it for
you. `claude-relogin.sh --restore` undoes the prep if the login fails.
