#!/bin/bash
# =============================================================================
# AI CODING DOTFILES — runs on EVERY new Codespace
# =============================================================================
set -e
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   🚀 Setting up AI Coding Environment       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Basic tooling (already in universal image, but ensure) ──────────
echo "🐍 Python: $(python3 --version 2>/dev/null || echo 'N/A')"
echo "📦 npm:    $(npm --version 2>/dev/null || echo 'N/A')"

# ── 2. Install OpenCode CLI ─────────────────────────────────────────────
echo ""
echo "📦 Installing OpenCode CLI..."
if npm install -g @opencode-ai/cli 2>/dev/null; then
    echo "  ✅ OpenCode CLI installed (npm)"
elif npm install -g opencode 2>/dev/null; then
    echo "  ✅ OpenCode CLI installed (npm)"
elif curl -fsSL https://get.opencode.ai/install.sh | bash 2>/dev/null; then
    echo "  ✅ OpenCode CLI installed (installer)"
else
    echo "  ⚠️  OpenCode CLI — skipped (not available yet)"
fi

# ── 3. VS Code Extensions ──────────────────────────────────────────────
echo ""
echo "🧩 Installing VS Code extensions..."
for ext in \
    "wienans.opencode-zen-chat-provider" \
    "calgan.oai-provider" \
    "github.vscode-pull-request-github" \
    "ms-python.python"; do
    code --install-extension "$ext" --force 2>/dev/null && \
        echo "  ✅ $ext" || echo "  ⚠️  $ext"
done

# ── 4. Configure OAIProvider from Codespaces Secrets ───────────────────
echo ""
echo "🔑 Configuring OAIProvider..."

for d in "${HOME}/.vscode-remote/data/Machine" "${HOME}/.vscode-server/data/Machine"; do
    [ -d "$d" ] && { SD="$d"; break; }
done
[ -z "${SD}" ] && { echo "  ⚠️  VS Code not ready yet – OAIProvider will configure on next open"; exit 0; }

SF="${SD}/settings.json"
mkdir -p "${SD}"
[ ! -f "$SF" ] && echo '{}' > "$SF"

python3 << 'PYEOF'
import json, os

s = os.environ.get("SETTINGS_FILE", "")
if not s or not os.path.exists(s):
    exit(0)

with open(s, "r") as f:
    cfg = json.load(f)

providers = []

# ── Kimi / Fireworks ──
fw = os.environ.get("FIREWORKS_API_KEY", "")
if fw:
    providers.append({
        "id": "kimi",
        "displayName": "kimi (Fireworks)",
        "baseUrl": "https://api.fireworks.ai/inference/v1",
        "apiKey": fw,
        "models": [
            {"id": "accounts/fireworks/models/kimi-k2p6", "name": "kimi2.6",
             "maxInputTokens": 500000, "maxOutputTokens": 4096, "supportsToolCalling": True},
            {"maxInputTokens": 128000, "maxOutputTokens": 4096, "supportsToolCalling": True},
            {"maxInputTokens": 128000, "maxOutputTokens": 4096, "supportsToolCalling": True},
            {"maxInputTokens": 128000, "maxOutputTokens": 4096, "supportsToolCalling": True}
        ]
    })

# ── OpenAI ──
oa = os.environ.get("OPENAI_API_KEY", "")
if oa:
    providers.append({
        "id": "openai",
        "displayName": "OpenAI",
        "baseUrl": "https://api.openai.com/v1",
        "apiKey": oa,
        "models": [
            {"id": "gpt-4o", "name": "GPT-4o",
             "maxInputTokens": 128000, "maxOutputTokens": 16384, "supportsToolCalling": True},
            {"id": "gpt-4o-mini", "name": "GPT-4o Mini",
             "maxInputTokens": 128000, "maxOutputTokens": 16384, "supportsToolCalling": True}
        ]
    })

# ── Anthropic ──
an = os.environ.get("ANTHROPIC_API_KEY", "")
if an:
    providers.append({
        "id": "anthropic",
        "displayName": "Anthropic",
        "baseUrl": "https://api.anthropic.com/v1",
        "apiKey": an,
        "models": [
            {"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4",
             "maxInputTokens": 200000, "maxOutputTokens": 8192, "supportsToolCalling": True}
        ]
    })

# ── OpenRouter ──
or_k = os.environ.get("OPENROUTER_API_KEY", "")
if or_k:
    providers.append({
        "id": "openrouter",
        "displayName": "OpenRouter",
        "baseUrl": "https://openrouter.ai/api/v1",
        "apiKey": or_k,
        "models": [
            {"id": "google/gemini-2.5-pro", "name": "Gemini 2.5 Pro",
             "maxInputTokens": 1000000, "maxOutputTokens": 8192, "supportsToolCalling": True}
        ]
    })

if providers:
    cfg["openai-compat-provider.providers"] = providers
    with open(s, "w") as f:
        json.dump(cfg, f, indent=4)
    print(f"  ✅ {len(providers)} provider(s) configured:")
    for p in providers:
        print(f"     • {p['displayName']}")
else:
    print("  ℹ️  No API keys found in environment")
    print("     Add them at: https://github.com/settings/codespaces/secrets")

PYEOF

export SETTINGS_FILE="$SF"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✅ AI Coding Environment Ready!           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Extensions installed:"
echo "    • OpenCode Zen (chat provider)"
echo "    • OAIProvider (custom LLM endpoints)"
echo "    • GitHub Pull Requests"
echo "    • Python"
echo ""
echo "  LLM providers auto-configured from secrets"
echo ""

