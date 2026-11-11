#!/bin/zsh
# アプリと同じ経路で推敲を試す。使い方: ./tools/try-rewrite.sh [e2b|e4b] < 下書き.txt
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
mkdir -p "$ROOT/build"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name FudeTry \
  -module-cache-path "$TMP/fude-module-cache" \
  $(ls "$ROOT"/Sources/Fude/*.swift | grep -v /App.swift) "$ROOT/tools/TryRewrite.swift" \
  -o "$ROOT/build/fude-try-rewrite"
"$ROOT/build/fude-try-rewrite" "$@"
