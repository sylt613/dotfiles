# CLAUDE.md — context for Claude Code sessions in this repo

This is sylt613's **GitHub Codespaces dotfiles** repo. Its one job: every new
codespace comes up with the Claude Code VS Code extension installed, logged in
via Codespaces secrets, in `bypassPermissions` (full-auto) mode, with a smart
keep-alive — PLUS a full-auto Claude TUI already running in a detached **tmux**
session (`claude-tui` to attach) that survives disconnects, while the keep-alive
keeps the machine awake only *while that Claude is working*. The whole chain is
verified working end-to-end in a real codespace (see the `codespace-e2e`
workflow — run it to re-verify any time).

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

8. **The persistent Claude TUI lives in tmux** (`claude-tmux.sh`), and getting
   it to open *straight to a usable full-auto prompt* depends on THREE
   non-obvious gates — all THREE must be cleared or the detached pane hangs on a
   dialog (and you can't see it without attaching). Each was verified in a REAL
   codespace, not a sim — see the warning at the end about why:
   - **`skipDangerousModePermissionPrompt: true` in `~/.claude/settings.json`**
     (install.sh sets it). Suppresses the "WARNING: Bypass Permissions mode —
     1. No, exit / 2. Yes, I accept" startup dialog. In current Claude Code the
     in-app `bypassPermissionsModeAccepted` flag does NOT suppress this — only
     this settings key does. Its default is "No, exit", so a stray newline kills
     the session.
   - **Launch with `--permission-mode bypassPermissions`, NOT the
     `--dangerously-skip-permissions` flag.** The flag forces bypass but is
     redundant given the settings, and the mode flag still works even if
     `settings.json` somehow lost `defaultMode`.
   - **Pre-seed `projects["<workspace>"].hasTrustDialogAccepted=true` in
     `~/.claude.json`** (claude-tmux.sh writes it, merge-only, `sys.exit(3)`
     non-clobber per invariant 5). The folder-trust dialog ("Is this a project
     you trust?") is a separate gate that nothing else satisfies.
   "Stay awake" mirrors the Fly watchdog at
   `flyio-instance-control/v1-claude/keepalive.sh` — force flag, OR Claude
   processes burned >= `BUSY_JIFFIES` of CPU in the last poll, OR a transcript
   `.jsonl` write within the grace window. A Claude process must exist for the
   transcript signal to count (else a stale file pins the box).
   Two of the Fly script's four signals are deliberately NOT ported, because
   both were measured on a live codespace and neither discriminates here:
   `any_attached` (all 4 tmux sessions report `session_attached=1` at all times)
   and `last_tmux_activity` (newest pane activity reads 0s ago constantly, the
   TUI repaints). Porting either would pin a 4-core box at ~$0.36/hr forever.
   (An earlier version of this file claimed an idle pane's `window_activity` is
   frozen. It is not — measured.)
   `BUSY_JIFFIES` defaults to 3% average CPU, not Fly's ~1%, for the same
   repaint reason. Every decision logs its CPU delta so it can be recalibrated
   from real data.
   ⚠️ **Do not "verify" the no-dialog launch locally inside a Claude session.**
   A Claude you spawn inherits `CLAUDE_CODE_CHILD_SESSION=1`/`CLAUDECODE=1` and
   skips the bypass warning, so every local repro looks clean and lies. The only
   trustworthy test is a real fresh codespace (the `codespace-e2e` Check 5, or
   `gh codespace create` + ssh + `tmux capture-pane -t claude -p`).

## Architecture (read order)

- `install.sh` — entrypoint GitHub runs at codespace creation
- `claude-auth.sh` — auth seeding (see invariants 1–2)
- `vscode-setup.sh` — background extension installer (invariant 4)
- `session-init.sh` — `.bashrc` hook: self-heals auth/extension/keep-alive/tmux
- `claude-tmux.sh` — starts (and re-creates after stop/start) the detached
  full-auto Claude tmux session; pre-trusts the workspace (see invariant 8)
- `cs_keepalive.sh` — holds a real client session (`gh codespace ssh` to self)
  while Claude works; releases it when idle so the box can stop. See the
  keep-alive invariant below.
- `ai-check` — in-codespace diagnostic; `✅ READY` or says exactly what's wrong
- `setup-secrets.sh` — run by the USER on their machine/working codespace:
  uploads the token to user Codespaces secrets + grants all repos
- `devcontainer-template/devcontainer.json` — per-repo option; GitHub installs
  extensions natively, postCreate runs this bootstrap even without the toggle,
  postStart restarts the keep-alive after every stop/start

## Keep-alive invariant — a codespace's idle timeout is IMMUTABLE

`idle_timeout_minutes` is fixed when the codespace is **created** and cannot be
changed afterwards. `PATCH /user/codespaces/{name}` does not accept the field:
it returns **200 and silently ignores it** (verified 2026-07-31 — PATCH 200,
follow-up GET still read 30). `gh codespace edit` has no `--idle-timeout` flag.
Any code that "sets the timeout at runtime" is a no-op; the old keep-alive did
exactly this and protected nothing for months because `curl` exits 0 on a 200.

What actually defers the idle stop is a **live client connection**. Background
processes do not count — GitHub's docs say terminal output counts as activity,
but staff have confirmed that only holds while a client is attached, which is
why closing the browser kills a box that is mid-build. So the keep-alive holds
one: `gh codespace ssh` from the box to itself, printing a line every 30s.

NOTE the difference from the Fly watchdog: Fly's timer is reset by an inbound
request through its proxy, so a self-ping to its own hostname works. A
codespace's timer does **not** respond to self-directed HTTP or to internal CPU
load — only to a client session. Do not reason from one to the other.

Verified twice on 2026-07-31:

1. A/B on two throwaway codespaces created with a 5-minute timeout. The
   control, left alone, went `ShuttingDown` at 4m56s and `Shutdown` at 5m57s.
   The twin, holding a self-SSH session and never opened in a browser, stayed
   `Available` 17m07s (3.4x) until deleted by hand.
2. Better, unattended, on this real box (30-min timeout): held from 00:36 to
   02:09 — 1h33m through three 30-min lease recycles. At 02:09:55 Claude went
   quiet, the watchdog released, and the box then genuinely stopped (fresh boot
   at 02:48). Held ⇒ alive past 3x the timeout; released ⇒ stopped ~30 min
   later. That is the causal pair.

Re-run one of those rather than trusting this paragraph if you change the
mechanism.

To change the timeout for **new** codespaces, set the account default at
github.com/settings/codespaces (5–240 min). It does not affect existing ones.

## Testing — run before any push

```bash
bash test/run-tests.sh    # sandbox suite (fake HOME, mock CLIs) — 64 assertions
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
- Attach to the always-on full-auto Claude: `claude-tui` (or `tmux attach -t claude`)
- Proof of life: dispatch `codespace-e2e`
