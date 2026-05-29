#!/bin/bash
set -e
echo "🚀 AI Coding Environment Setup"

# Extensions
echo "🧩 Installing extensions..."
for ext in "wienans.opencode-zen-chat-provider" "calgan.oai-provider" "github.vscode-pull-request-github" "ms-python.python"; do
    code --install-extension "$ext" --force 2>/dev/null && echo "  ✅ $ext" || echo "  ⚠️ $ext"
done

# OAIProvider config
echo "🔑 Configuring OAIProvider..."
for d in "${HOME}/.vscode-remote/data/Machine" "${HOME}/.vscode-server/data/Machine"; do
    [ -d "$d" ] && { SD="$d"; break; }
done
[ -z "${SD}" ] && { echo "  ⚠️ VS Code not ready"; exit 0; }

SF="${SD}/settings.json"
mkdir -p "${SD}"
[ ! -f "$SF" ] && echo '{}' > "$SF"

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
export SETTINGS_FILE="$SF"
echo "✅ Done!"
