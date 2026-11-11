#!/bin/zsh
# 推敲に使うもの（llama.cpp とモデル）を取ってくる。使い方: ./scripts/setup.sh [e2b|e4b|all]
# 既定は e4b（約 5 GB。アプリの既定）。e2b は約 3.1 GB で、軽いが文はやや硬い。ネットにつながるのはこのスクリプトだけ。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

LLAMA_TAG="b12110"   # Gemma 4 が動くことを確かめた版。上げるときは推敲を試してから
WHICH="${1:-e4b}"

mkdir -p "$ROOT/vendor" "$ROOT/models"

if [[ ! -x "$ROOT/vendor/llama-$LLAMA_TAG/llama-server" ]]; then
  echo "llama.cpp $LLAMA_TAG を取ってきます"
  curl -fL --progress-bar -o "$ROOT/vendor/llama.tgz" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
  tar xzf "$ROOT/vendor/llama.tgz" -C "$ROOT/vendor"
  rm "$ROOT/vendor/llama.tgz"
  xattr -dr com.apple.quarantine "$ROOT/vendor/llama-$LLAMA_TAG" 2>/dev/null || true
fi
ln -sfn "llama-$LLAMA_TAG" "$ROOT/vendor/llama"

fetch() {
  local name="gemma-4-$1-it-Q4_K_M.gguf"
  if [[ -f "$ROOT/models/$name" ]]; then
    echo "$name はあります"
    return
  fi
  echo "$name を取ってきます"
  curl -fL --progress-bar -o "$ROOT/models/$name.part" \
    "https://huggingface.co/unsloth/gemma-4-$1-it-GGUF/resolve/main/$name"
  mv "$ROOT/models/$name.part" "$ROOT/models/$name"
}

case "$WHICH" in
  e2b) fetch E2B ;;
  e4b) fetch E4B ;;
  all) fetch E2B; fetch E4B ;;
  *) echo "e2b・e4b・all のどれかを指定してください"; exit 1 ;;
esac
echo "準備ができました"
