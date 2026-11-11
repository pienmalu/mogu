#!/bin/zsh
# アイコンを作る。Resources/AppIcon.icns と、確認用の build/shots/appicon.png・menubar.png。
# iconutil はサンドボックスの中では動かないので、外で実行する。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
mkdir -p "$ROOT/build/shots"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name FudeIcon \
  -module-cache-path "$TMP/fude-module-cache" \
  "$ROOT/Sources/Fude/BrushMark.swift" "$ROOT/tools/Icon.swift" -o "$ROOT/build/fude-icon"
rm -rf "$ROOT/build/AppIcon.iconset"
"$ROOT/build/fude-icon" "$ROOT/build/AppIcon.iconset" "$ROOT/build/shots"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "できました: Resources/AppIcon.icns"
