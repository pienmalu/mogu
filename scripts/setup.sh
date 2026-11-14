#!/bin/zsh
# 推敲と議事録に使うもの（llama.cpp、speech.cpp、モデル）を取ってくる。使い方: ./scripts/setup.sh [e2b|e4b|all|meeting]
# 既定は e4b（約 5 GB。アプリの既定）。e2b は約 3.1 GB で、軽いが文はやや硬い。
# meeting は、議事録の文字起こしに使う speech.cpp と Haas-ja（0.66 GB）、Silero VAD（1 MB）。要約には e4b か e2b も要る。
# ネットにつながるのはこのスクリプトだけ。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

LLAMA_TAG="b12110"   # Gemma 4 が動くことを確かめた版。上げるときは推敲を試してから
SPEECH_VERSION="0.10.1"   # 上げるときは ./tools/try-meeting.sh で文字起こしを試してから
WHICH="${1:-e4b}"

# 議事録の文字起こし。speech.cpp（コマンド1つ）を vendor/ に置き、リリースの SHA-256 と照らし合わせる。
# モデルは speech.cpp の既定のフォルダ（~/Library/Caches/speech.cpp/models。~/models/speech.cpp からリンクしてある）に
# 取ってきて、models/ にリンクを張る。Poko や Kanpe と同じファイルを使う。
if [[ "$WHICH" == "meeting" ]]; then
  ZIP="speech-$SPEECH_VERSION-macos-arm64-metal.zip"
  URL="https://github.com/nyosegawa/speech.cpp/releases/download/v$SPEECH_VERSION"
  mkdir -p "$ROOT/vendor" "$ROOT/models"
  if [[ "$("$ROOT/vendor/speech" --version 2>/dev/null)" != "speech.cpp $SPEECH_VERSION"* ]]; then
    echo "speech.cpp $SPEECH_VERSION を取ってきます"
    curl -fsSL -o "$ROOT/vendor/$ZIP" "$URL/$ZIP"
    curl -fsSL -o "$ROOT/vendor/SHA256SUMS" "$URL/SHA256SUMS"
    (cd "$ROOT/vendor" && grep " $ZIP\$" SHA256SUMS | shasum -a 256 -c -)
    unzip -q -o "$ROOT/vendor/$ZIP" -d "$ROOT/vendor"
    rm "$ROOT/vendor/$ZIP"
    xattr -dr com.apple.quarantine "$ROOT/vendor/speech" "$ROOT"/vendor/libspeech*.dylib 2>/dev/null || true
  fi
  "$ROOT/vendor/speech" --version
  ln -sf "$("$ROOT/vendor/speech" pull haas-ja-v1.0:q8_0)" "$ROOT/models/haas-ja-v1.0-q8_0.gguf"
  ln -sf "$("$ROOT/vendor/speech" pull silero-vad)" "$ROOT/models/silero-vad.gguf"
  echo "準備ができました"
  exit 0
fi

# モデルの実体は、ほかのアプリとも共有するフォルダに置き、models/ にはリンクだけを張る。
# 置き場所は LLAMA_MODEL_DIR で変えられる（既定は ~/models/llama.cpp）。
SHARED="${LLAMA_MODEL_DIR:-$HOME/models/llama.cpp}"

mkdir -p "$ROOT/vendor" "$ROOT/models" "$SHARED"

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
  if [[ -f "$SHARED/$name" ]]; then
    echo "$name はあります"
  elif [[ -f "$ROOT/models/$name" && ! -L "$ROOT/models/$name" ]]; then
    echo "$name を $SHARED に移します"  # 前の版の setup.sh が models/ に直接置いたもの
    mv "$ROOT/models/$name" "$SHARED/$name"
  else
    echo "$name を取ってきます"
    curl -fL --progress-bar -o "$SHARED/$name.part" \
      "https://huggingface.co/unsloth/gemma-4-$1-it-GGUF/resolve/main/$name"
    mv "$SHARED/$name.part" "$SHARED/$name"
  fi
  ln -sf "$SHARED/$name" "$ROOT/models/$name"
}

case "$WHICH" in
  e2b) fetch E2B ;;
  e4b) fetch E4B ;;
  all) fetch E2B; fetch E4B ;;
  *) echo "e2b・e4b・all・meeting のどれかを指定してください"; exit 1 ;;
esac
echo "準備ができました"
