#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^version: *//p' shard.yml | head -1)
ARCH=$(uname -m)
NAME="agent-cli-${VERSION}-macos-${ARCH}"
OUT="dist/${NAME}"

rm -rf "$OUT" "dist/${NAME}.tar.gz"
mkdir -p "$OUT"

echo "Installing dependencies..."
shards install

echo "Building release binary..."
shards build agent-cli --release

cp bin/agent-cli "$OUT/agent-cli"
cp README.md LICENSE "$OUT/"

cat > "$OUT/README.txt" <<EOF
agent-cli ${VERSION} (macOS ${ARCH})

Run:
  ./agent-cli --workspace /path/to/repo --provider deepseek

Configuration (CLI > environment > provider defaults):
  LLM_PROVIDER, LLM_ENDPOINT, LLM_MODEL, LLM_API_KEY
  OPENAI_API_KEY / DEEPSEEK_API_KEY when the provider is explicitly named
  AGENT_WORKSPACE, AGENT_SESSION, AGENT_AUTO_APPROVE, AGENT_READ_ONLY

The binary is built for this machine's architecture (${ARCH}).
For distribution to other Macs, build on that architecture or add a
universal build (arm64 + x86_64) in CI.
EOF

# Ad-hoc signing helps local Gatekeeper behavior; it is not notarization.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$OUT/agent-cli" >/dev/null 2>&1 || true
fi

tar -czf "dist/${NAME}.tar.gz" -C dist "$NAME"
echo "Built dist/${NAME}.tar.gz"
