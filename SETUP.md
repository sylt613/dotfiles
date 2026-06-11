# Claude Code Codespaces — Setup Instructions

## What this does

Every new GitHub Codespace you create will have:
- **Claude Code VS Code extension** installed and logged in automatically
- **Full-auto (bypassPermissions) mode** enabled — no permission prompts
- Claude CLI installed and authenticated
- Smart keep-alive (prevents idle timeout while Claude is working)
- git/gh wired with your credentials

---

## Fastest path: one command

On any machine where you're logged into Claude Code and the
[gh CLI](https://cli.github.com) — your laptop **or an already-working
codespace** (those have gh pre-wired with your PAT):

```bash
claude setup-token        # approve in browser → prints sk-ant-oat01-…
git clone https://github.com/sylt613/dotfiles && cd dotfiles
bash setup-secrets.sh     # paste the token when asked
```

It uploads the token to your GitHub Codespaces user secrets as
`CLAUDE_CODE_OAUTH_TOKEN` (the static ~1-year token — **the** reliable auth)
and grants it to **all your current repos** automatically. Then check the
dotfiles toggle (step 1 below) once, and you're done.

**When you create a new repo**, re-run:

```bash
bash setup-secrets.sh --grant
```

This updates the repo grants without re-prompting for secret values.

## Why can't this be 100% automatic?

Three things have no API and/or require *your* interactive login — no script,
bot, or GitHub Action can do them:

1. **The token itself** — `claude setup-token` (or the Claude login that
   creates `~/.claude/.credentials.json`) requires you logging into claude.ai
   in a browser. Nothing can mint it on your behalf.
2. **The dotfiles toggle** — GitHub has no API for "Automatically install
   dotfiles". One checkbox, once, at github.com/settings/codespaces.
3. **A GitHub Action can't write your account secrets** — the workflow token
   is repo-scoped; user Codespaces secrets need your personal `codespace`-scope
   auth (which is exactly what `setup-secrets.sh` uses via your local gh CLI).
4. **GitHub user secrets have no "all repos" visibility** — unlike org secrets,
   user Codespace secrets can only be `selected` repos. The `--grant` command
   adds every current repo; run it again for new ones.

Everything else *is* automatic — that's what these dotfiles do at codespace
creation. And if a codespace of yours already auto-logged-in before, your
secrets already exist: at most grant them to new repos (one re-run of
`setup-secrets.sh`, or tick checkboxes in the web UI).

## One-time setup (manual route — same result as the script)

### 1. Enable dotfiles in GitHub Codespaces settings

Go to [github.com/settings/codespaces](https://github.com/settings/codespaces):
- Check **"Automatically install dotfiles"**
- Select `sylt613/dotfiles` from the dropdown

### 2. Get your Claude auth token

On any machine where you're already logged into Claude Code, run:

```bash
claude setup-token
```

Copy the `sk-ant-oat01-…` value — that's your `CLAUDE_CODE_OAUTH_TOKEN`.

### 3. Add the secrets in GitHub Codespaces settings

Still on [github.com/settings/codespaces](https://github.com/settings/codespaces), add these secrets:

| Secret | Required? | What to put in it |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | **Yes** | The `sk-ant-oat01-…` value from `claude setup-token` — valid ~1 year, immune to refresh-token rotation |
| `CLAUDE_CREDENTIALS_JSON` | ⚠️ Avoid (opt-in via `setup-secrets.sh --with-creds`) | A snapshot that **dies** the moment any Claude install rotates the refresh token; a dead one used to shadow the valid token and block login. The dotfiles now refuse to seed it when expired, but it's still just noise |
| `GH_CODESPACE_PAT` | Optional (recommended) | GitHub Personal Access Token (classic, `repo` + `codespace` scopes) — needed for keep-alive and git auth on private repos |
| `FIREWORKS_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | Optional | For using additional models in the OAI-provider extension |

> **Critical:** After adding each secret, click it and **grant access to every repository** you open Codespaces on. Secrets not granted to a repo are invisible to that codespace.

### 4. Create a new codespace

Secrets only take effect in codespaces created or restarted **after** they're added:
- **New secret** → create a fresh codespace, or run *Codespaces: Rebuild Container*
- **Changed/added secret on existing codespace** → restart the codespace

---

## Verify it worked

Open a terminal in the new codespace and run:

```bash
ai-check
```

You'll see `✅ READY` or a plain-English explanation of exactly what's missing.

---

## Per-repo devcontainer (more reliable, works without the dotfiles toggle)

For repos you use frequently, copy [`devcontainer-template/devcontainer.json`](devcontainer-template/devcontainer.json) to `<your-repo>/.devcontainer/devcontainer.json`. This makes GitHub install the extensions during codespace creation itself (instead of in the background after), and the full setup runs automatically even if the dotfiles toggle is off.

To make codespaces start instantly: enable a **prebuild** (repo → Settings → Codespaces → *Set up prebuild*). Prebuilds bake the extensions in — login stays with the dotfiles secrets so tokens are never stored in the prebuild snapshot.

---

## Maintenance (everything there is, ever)

| When | What |
|---|---|
| **~once a year** — the token expires | `claude setup-token` → `bash setup-secrets.sh`. That's the whole renewal. |
| **you create a new repo** | `bash setup-secrets.sh --grant` (GitHub can't grant user secrets to "all future repos") — or let the daily `grant-secrets` workflow catch it |
| **a codespace shows a login screen** | `rm -f ~/.claude/.credentials.json` inside it, restart Claude — a stale credentials file was shadowing the token |
| **you want proof it all works** | repo → Actions → `codespace-e2e` → Run workflow. It creates a real codespace, verifies the extension + auth + an actual Claude conversation, and deletes it. Green = everything works. |

---

## Recovery (if a codespace's Claude config breaks)

A codespace rebuild wipes `$HOME`. To restore by hand inside a running codespace:

```bash
# Re-run the full setup (re-seeds auth, re-enables bypassPermissions)
bash ~/.ai-dotfiles/install.sh

# Or if the dotfiles cloned to the persisted share:
bash /workspaces/.codespaces/.persistedshare/dotfiles/install.sh

# If STILL logged out: a dead credentials file is shadowing the token
rm -f ~/.claude/.credentials.json

# Confirm everything is working
ai-check
```

If `~/.claude.json` was damaged and Claude lost its login state (check: `ai-check` reports auth missing after the above), Claude keeps a backup:

```bash
cp ~/.claude.json.backup ~/.claude.json
```

---

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Extension not installed / auth missing | `cat ~/.dotfiles-install.log` |
| Extension installed but wrong version | `cat ~/.dotfiles-vscode-setup.log` |
| Secrets not visible in the codespace | `printenv \| grep -E 'CLAUDE\|GH_'` — empty means not granted to this repo, or needs a restart |
| GitHub creation log | `/workspaces/.codespaces/.persistedshare/creation.log` |

Still stuck? `ai-check` is the fastest diagnostic — it checks every piece and tells you exactly what's missing.
