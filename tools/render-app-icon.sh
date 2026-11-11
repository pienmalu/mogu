#!/bin/zsh
# アプリのアイコン Resources/AppIcon.icns を、正方形の絵 Resources/AppIcon.png から作り直す。
# 使い方: ./tools/render-app-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="${TMPDIR:-/tmp}"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$TMP/mogu-module-cache" \
  tools/render-app-icon/main.swift -o build/render-app-icon
rm -rf build/AppIcon.iconset
build/render-app-icon Resources/AppIcon.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
