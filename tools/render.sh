#!/bin/zsh
# 本文の見た目を PNG に描く（ライトとダーク）。使い方: ./tools/render.sh [出力フォルダ] [--window]
# --window をつけると窓全体も撮る（画面に一瞬出る。画面収録の許可が要る）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
mkdir -p "$ROOT/build"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name FudeRender \
  -module-cache-path "$TMP/fude-module-cache" \
  $(ls "$ROOT"/Sources/Fude/*.swift | grep -v /App.swift) "$ROOT/tools/Render.swift" \
  -o "$ROOT/build/fude-render"
"$ROOT/build/fude-render" "$@"
