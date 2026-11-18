#!/bin/zsh
# アプリのアイコン Resources/AppIcon.icns を、元の絵 Resources/AppIcon.svg から作り直す。
# SVG を Chrome で 1024×1024 の PNG（AppIcon.png と、16・32px 用の AppIcon-small.png）に書き出し、
# それを macOS のアイコンの角丸に切り抜いて icns にまとめる。
# 使い方: ./tools/render-app-icon.sh（サンドボックスの外で動かす。中では Chrome も iconutil も動かない）
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="${TMPDIR:-/tmp}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p build

if [[ -x "$CHROME" ]]; then
  for name in AppIcon AppIcon-small; do
    rm -f "Resources/$name.png"
    "$CHROME" --headless=new --hide-scrollbars --no-first-run --disable-gpu --force-device-scale-factor=1 \
      --user-data-dir="$TMP/mogu-icon-chrome" --window-size=1024,1024 \
      --screenshot="$PWD/Resources/$name.png" "file://$PWD/Resources/$name.svg" >/dev/null 2>&1 || true
    [[ -f "Resources/$name.png" ]] || { echo "Resources/$name.svg を PNG にできなかった" >&2; exit 1; }
    echo "wrote Resources/$name.png"
  done
else
  echo "Chrome がないので SVG は書き出さず、今ある Resources/AppIcon.png と AppIcon-small.png から作る" >&2
fi

swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$TMP/mogu-module-cache" \
  tools/render-app-icon/main.swift -o build/render-app-icon
rm -rf build/AppIcon.iconset
build/render-app-icon Resources/AppIcon.png Resources/AppIcon-small.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
