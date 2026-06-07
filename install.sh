#!/bin/bash
set -e
echo "🚀 AI Coding Environment Setup"

# Extensions
echo "🧩 Installing extensions..."
for ext in "wienans.opencode-zen-chat-provider" "calgan.oai-provider" "github.vscode-pull-request-github" "ms-python.python" "anthropic.claude-code"; do
    code --install-extension "$ext" --force 2>/dev/null && echo "  ✅ $ext" || echo "  ⚠️ $ext"
done

# OAIProvider config
echo "🔑 Configuring OAIProvider..."
for d in "${HOME}/.vscode-remote/data/Machine" "${HOME}/.vscode-server/data/Machine"; do
    [ -d "$d" ] && { SD="$d"; break; }
done

if [ -n "${SD}" ]; then
    SF="${SD}/settings.json"
    mkdir -p "${SD}"
    [ ! -f "$SF" ] && echo '{}' > "$SF"
    export SETTINGS_FILE="$SF"

    python3 << 'INNERPY'
import json, os
s = os.environ.get("SETTINGS_FILE","")
if not s or not os.path.exists(s): exit(0)
with open(s,"r") as f: cfg = json.load(f)
pro = []
fw = os.environ.get("FIREWORKS_API_KEY","")
if fw: pro.append({"id":"kimi","displayName":"kimi","baseUrl":"https://api.fireworks.ai/inference/v1","apiKey":fw,"models":[{"id":"accounts/fireworks/models/kimi-k2p6","name":"kimi2.6","maxInputTokens":500000,"maxOutputTokens":4096,"supportsToolCalling":True},{"maxInputTokens":128000,"maxOutputTokens":4096,"supportsToolCalling":True},{"maxInputTokens":128000,"maxOutputTokens":4096,"supportsToolCalling":True},{"maxInputTokens":128000,"maxOutputTokens":4096,"supportsToolCalling":True}]})
oa = os.environ.get("OPENAI_API_KEY","")
if oa: pro.append({"id":"openai","displayName":"OpenAI","baseUrl":"https://api.openai.com/v1","apiKey":oa,"models":[{"id":"gpt-4o","name":"GPT-4o","maxInputTokens":128000,"maxOutputTokens":16384,"supportsToolCalling":True}]})
an = os.environ.get("ANTHROPIC_API_KEY","")
if an: pro.append({"id":"anthropic","displayName":"Anthropic","baseUrl":"https://api.anthropic.com/v1","apiKey":an,"models":[{"id":"claude-sonnet-4-20250514","name":"Claude Sonnet 4","maxInputTokens":200000,"maxOutputTokens":8192,"supportsToolCalling":True}]})
if pro:
    cfg["openai-compat-provider.providers"] = pro
    with open(s,"w") as f: json.dump(cfg,f,indent=4)
    print(f"  ✅ {len(pro)} provider(s)")
else:
    print("  ℹ️ No keys found")
INNERPY
else
    echo "  ⚠️ VS Code not ready, skipping provider config"
fi

# ── Claude Code CLI ──────────────────────────────────────────────────────────
echo "🤖 Setting up Claude Code CLI..."

# Ensure Node.js is available
if ! command -v node &>/dev/null; then
    echo "  📦 Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - >/dev/null 2>&1
    sudo apt-get install -y nodejs >/dev/null 2>&1
fi

# Install Claude Code globally
if ! command -v claude &>/dev/null; then
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 && echo "  ✅ claude installed" || echo "  ⚠️ claude install failed"
else
    echo "  ✅ claude already installed ($(claude --version 2>/dev/null | head -1))"
fi

# ── Write credentials.json from CLAUDE_CREDENTIALS_JSON (has refresh token) ──
if [ -n "${CLAUDE_CREDENTIALS_JSON:-}" ]; then
    echo "  🔑 Seeding ~/.claude/.credentials.json from CLAUDE_CREDENTIALS_JSON..."
    mkdir -p "${HOME}/.claude"
    CRED_DST="${HOME}/.claude/.credentials.json"
    printf '%s' "$CLAUDE_CREDENTIALS_JSON" | base64 -d > /tmp/.cred_seed.json 2>/dev/null || true
    if python3 -c "import json; json.load(open('/tmp/.cred_seed.json'))['claudeAiOauth']" 2>/dev/null; then
        seed_exp=$(python3 -c "import json; print(json.load(open('/tmp/.cred_seed.json'))['claudeAiOauth'].get('expiresAt',0))" 2>/dev/null || echo 0)
        cur_exp=0
        if [ -f "$CRED_DST" ]; then
            cur_exp=$(python3 -c "import json; print(json.load(open('$CRED_DST'))['claudeAiOauth'].get('expiresAt',0))" 2>/dev/null || echo 0)
        fi
        if [ ! -f "$CRED_DST" ] || [ "${seed_exp:-0}" -gt "${cur_exp:-0}" ]; then
            cp /tmp/.cred_seed.json "$CRED_DST"
            chmod 600 "$CRED_DST"
            echo "  ✅ credentials.json written (with refresh token)"
        else
            echo "  ✅ credentials.json kept (live copy is newer)"
        fi
    else
        echo "  ⚠️ CLAUDE_CREDENTIALS_JSON is not valid JSON — skipping"
    fi
    rm -f /tmp/.cred_seed.json
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "  ✅ OAuth token present via CLAUDE_CODE_OAUTH_TOKEN (no refresh token)"
else
    echo "  ⚠️ No Claude auth found — add CLAUDE_CODE_OAUTH_TOKEN to github.com/settings/codespaces"
fi

# Configure Claude Code to run all commands without permission prompts
echo "  ⚙️  Configuring auto-approve (bypassPermissions)..."
mkdir -p "${HOME}/.claude"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
[ ! -f "$CLAUDE_SETTINGS" ] && echo '{}' > "$CLAUDE_SETTINGS"
export CLAUDE_SETTINGS
python3 << 'CLAUDEPY'
import json, os
p = os.environ["CLAUDE_SETTINGS"]
with open(p) as f:
    try: cfg = json.load(f)
    except: cfg = {}
perms = cfg.get("permissions", {})
perms["defaultMode"] = "bypassPermissions"
cfg["permissions"] = perms
cfg.setdefault("theme", "auto")
with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
print("  ✅ All commands auto-approved")
CLAUDEPY

# ── Prevent codespace from stopping mid-Claude-session ───────────────────────
echo "⏰ Configuring smart keep-alive..."

# 1) Keep the default 15-min idle timeout (saves money when not working).
#    The pinger below only fires when Claude is actually running, so idle
#    codespaces still stop on schedule.
if [ -n "${CODESPACE_NAME:-}" ]; then
    gh api --method PATCH "/user/codespaces/$CODESPACE_NAME" \
        -f idle_timeout_minutes=15 >/dev/null 2>&1 && \
        echo "  ✅ Idle timeout set to 15 min (stops fast when idle)" || \
        echo "  ⚠️ Could not set idle timeout via API"
fi

# 2) Smart keep-alive: adjusts the codespace idle timeout dynamically.
#    Claude writes to .jsonl session files while processing; idle prompt = no writes.
#    Active Claude → set timeout to 240 min (won't be killed mid-task).
#    Idle/stopped Claude → set timeout back to 15 min (stops fast, saves money).
#    Requires GH_CODESPACE_PAT secret (full-scope PAT) — built-in GITHUB_TOKEN
#    lacks codespace scope so can't call the Codespaces API.
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GH_CODESPACE_PAT:-}" ]; then
    cat > /tmp/.cs_keepalive.sh << 'KEEPALIVE'
#!/bin/bash
CURRENT_TIMEOUT=15
while true; do
    MARKER=$(mktemp /tmp/.cs_mark.XXXXXX)
    sleep 120
    WROTE=$(find ~/.claude/projects ~/.claude/sessions \
        -newer "$MARKER" -name "*.jsonl" 2>/dev/null | head -1)
    rm -f "$MARKER"
    if [ -n "$WROTE" ]; then
        # Claude is actively working — extend timeout to 240 min
        if [ "$CURRENT_TIMEOUT" != "240" ]; then
            curl -s -o /dev/null -X PATCH \
                -H "Authorization: Bearer $GH_CODESPACE_PAT" \
                -H "Accept: application/vnd.github+json" \
                -H "Content-Type: application/json" \
                "https://api.github.com/user/codespaces/$CODESPACE_NAME" \
                -d '{"idle_timeout_minutes":240}' && CURRENT_TIMEOUT=240
        fi
    else
        # Claude is idle — restore 15-min timeout so codespace stops on schedule
        if [ "$CURRENT_TIMEOUT" != "15" ]; then
            curl -s -o /dev/null -X PATCH \
                -H "Authorization: Bearer $GH_CODESPACE_PAT" \
                -H "Accept: application/vnd.github+json" \
                -H "Content-Type: application/json" \
                "https://api.github.com/user/codespaces/$CODESPACE_NAME" \
                -d '{"idle_timeout_minutes":15}' && CURRENT_TIMEOUT=15
        fi
    fi
done
KEEPALIVE
    chmod +x /tmp/.cs_keepalive.sh
    pkill -f cs_keepalive 2>/dev/null || true  # kill stale instance from previous start
    nohup /tmp/.cs_keepalive.sh >>/tmp/.cs_keepalive.log 2>&1 &
    echo "  ✅ Smart keep-alive started (dynamic timeout: 240min active / 30min idle)"
else
    echo "  ⚠️ GH_CODESPACE_PAT not set — keep-alive inactive (add it at github.com/settings/codespaces)"
fi

# ── Wire up git and gh CLI with full-scope GitHub PAT ────────────────────────
echo "🔗 Configuring git and gh CLI..."
if [ -n "${GH_CODESPACE_PAT:-}" ]; then
    # gh CLI respects GH_TOKEN; prefer the full-scope PAT over the
    # repo-scoped auto-injected GITHUB_TOKEN so private repos and all APIs work
    grep -qxF 'export GH_TOKEN="$GH_CODESPACE_PAT"' ~/.bashrc 2>/dev/null || \
        echo 'export GH_TOKEN="$GH_CODESPACE_PAT"' >> ~/.bashrc
    # git credential store with full-scope PAT
    git config --global credential.helper store
    GIT_USER=$(GH_TOKEN="$GH_CODESPACE_PAT" gh api /user --jq '.login' 2>/dev/null || echo "sylt613")
    printf 'https://%s:%s@github.com\n' "$GIT_USER" "$GH_CODESPACE_PAT" > ~/.git-credentials
    chmod 600 ~/.git-credentials
    echo "  ✅ git and gh CLI configured with full-scope PAT (user: $GIT_USER)"
else
    echo "  ⚠️ GH_CODESPACE_PAT not set — git/gh will use repo-scoped token only"
fi

echo "✅ Done!"
