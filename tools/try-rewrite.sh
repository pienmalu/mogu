#!/bin/zsh
# アプリと同じ経路で推敲を試す。使い方: ./tools/try-rewrite.sh [e2b|e4b] < 下書き.txt
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
mkdir -p "$ROOT/build"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name MoguTry \
  -module-cache-path "$TMP/mogu-module-cache" \
  $(ls "$ROOT"/Sources/Mogu/*.swift | grep -v /App.swift) "$ROOT/tools/TryRewrite.swift" \
  -o "$ROOT/build/mogu-try-rewrite"
"$ROOT/build/mogu-try-rewrite" "$@"
