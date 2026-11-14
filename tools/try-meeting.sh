#!/bin/zsh
# 録音を、アプリと同じ経路（speech.cpp → 文字起こし → Gemma の要約）に流す。使い方: ./tools/try-meeting.sh 会議.wav [--no-summary]
# 音声はどんな形式でもよい（afconvert で 16 kHz・16 bit・モノラルの WAV に変えてから渡す）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
mkdir -p "$ROOT/build"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name MoguTryMeeting \
  -module-cache-path "$TMP/mogu-module-cache" \
  $(ls "$ROOT"/Sources/Mogu/*.swift | grep -v /App.swift) "$ROOT/tools/TryMeeting.swift" \
  -o "$ROOT/build/mogu-try-meeting"
WAV="$TMP/mogu-try-meeting.wav"
afconvert -f WAVE -d LEI16@16000 -c 1 "$1" "$WAV"
shift
"$ROOT/build/mogu-try-meeting" "$WAV" "$@"
