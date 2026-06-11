# CLAUDE.md — context for Claude Code sessions in this repo

This is sylt613's **GitHub Codespaces dotfiles** repo. Its one job: every new
codespace comes up with the Claude Code VS Code extension installed, logged in
via Codespaces secrets, in `bypassPermissions` (full-auto) mode, with a smart
keep-alive. The whole chain is verified working end-to-end in a real codespace
(see the `codespace-e2e` workflow — run it to re-verify any time).

## Hard-won invariants — do not regress these

1. **Token-first auth.** `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`,
   ~1 year, static) is THE auth. Anthropic **refresh tokens are single-use**:
   any Claude install that refreshes rotates the family and kills every stored
   copy of the old refresh token. Therefore credential snapshots
   (`CLAUDE_CREDENTIALS_JSON`) always decay — they are opt-in only
   (`setup-secrets.sh --with-creds`) and must never become the primary path.

2. **The shadowing bug (worst failure in this repo's history).** In Claude
   Code's auth precedence, `~/.claude/.credentials.json` OUTRANKS the
   `CLAUDE_CODE_OAUTH_TOKEN` env var. A dead-but-present credentials file
   produces `401 Invalid authentication credentials` / a login screen even
   though a valid token is wired in. `claude-auth.sh` therefore: never seeds
   expired credentials when a token exists, and deletes a previously-seeded
   byte-identical dead snapshot. Keep the `dead-creds-not-seeded` test green.

3. **Never schedule `claude-oauth-refresh`.** A cron refresh is guaranteed to
   decay into `invalid_grant` spam (see invariant 1) — it burned 8 failed runs
   before being made manual-only. Its preflight refuses to refresh unless
   `GH_PAT_SECRETS` exists, because a successful rotation that can't be saved
   destroys the only working copy.

4. **The `code` CLI does not exist while dotfiles run** (creation happens
   before the VS Code server is up). Extension installs go through
   `vscode-setup.sh`, a background watcher using the server's `code-server`
   binary under `/vscode/bin/.../bin/code-server` into
   `~/.vscode-remote/extensions` (works headlessly, ~25 s after creation,
   before any client attaches), with a remote-CLI + IPC-socket fallback.

5. **Never clobber Claude state.** `~/.claude.json` and
   `~/.claude/settings.json` are merged atomically (tmp + `os.replace`,
   chmod 600); unparseable non-trivial files are LEFT UNTOUCHED (`sys.exit(3)`
   pattern). A `cfg = {}` fallback once wiped the user's login + bypass mode.

6. **`install.sh` must never die halfway** — no `set -e`, every step
   best-effort, everything logged to `~/.dotfiles-install.log`. Never echo
   secret *values* into logs.

7. **GitHub user-level Codespaces secrets have no "all repos" visibility**
   (org secrets do, user secrets don't). Grants are explicit per-repo via
   `PUT /user/codespaces/secrets/<name>/repositories`. There is **no API at
   all** for the "Automatically install dotfiles" account toggle.

## Architecture (read order)

- `install.sh` — entrypoint GitHub runs at codespace creation
- `claude-auth.sh` — auth seeding (see invariants 1–2)
- `vscode-setup.sh` — background extension installer (invariant 4)
- `session-init.sh` — `.bashrc` hook: self-heals auth/extension/keep-alive
- `cs_keepalive.sh` — idle timeout 240 min while Claude works, 15 min idle
- `ai-check` — in-codespace diagnostic; `✅ READY` or says exactly what's wrong
- `setup-secrets.sh` — run by the USER on their machine/working codespace:
  uploads the token to user Codespaces secrets + grants all repos
- `devcontainer-template/devcontainer.json` — per-repo option; GitHub installs
  extensions natively, postCreate runs this bootstrap even without the toggle

## Testing — run before any push

```bash
bash test/run-tests.sh    # sandbox suite (fake HOME, mock CLIs) — 48 assertions
bash test/e2e-real.sh     # real VS Code server + marketplace, clean HOME
```

CI: `verify.yml` runs both on every push to main. The real-world canary is
`codespace-e2e.yml` (workflow_dispatch): creates an actual codespace, checks
install log → ai-check → extension dir → a real `claude -p` conversation,
always deletes the codespace. Requires `GH_PAT_SECRETS` Actions secret.

When changing auth/seeding behavior, add a scenario to `test/run-tests.sh`
(pattern: `new_sandbox` + `run_install VAR=...` + `assert_*`).

## Conventions

- Bash, no external deps beyond python3/curl/jq-in-CI; portable base64
  (`base64 | tr -d '\n'`, not `-w0`) where user machines may be macOS
- Secrets: values never printed; secret *names* are fine
- Workflows that depend on optional secrets must no-op green, not fail red
- User docs live in README.md (overview + runbook) and SETUP.md (step-by-step)
  — keep both in sync with behavior changes

## Maintenance runbook (what the user does, rarely)

- Yearly (token expiry) or after revocation: `claude setup-token` →
  `bash setup-secrets.sh`
- New repo: `bash setup-secrets.sh --grant` (or the daily `grant-secrets` cron)
- Codespace stuck on login screen (old clone): `rm -f ~/.claude/.credentials.json`
- Proof of life: dispatch `codespace-e2e`
