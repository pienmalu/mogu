#!/bin/zsh
# アプリを作る。使い方: ./scripts/build-app.sh [--install] [--open]
#   --install  ~/Applications に入れる（Dock や Launchpad から開けるようになる）。動いていれば先に終了させる
#   --open     作ったアプリを開く（--install と一緒なら、入れた方を開く）
# アプリ名と bundle ID はこの2行だけで決まる（Info.plist とコードはここから受け取る）。
APP_NAME="${APP_NAME:-Mogu}"
BUNDLE_ID="${BUNDLE_ID:-dev.haruka.mogu}"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/$APP_NAME.app"
TMP="${TMPDIR:-/tmp}"

mkdir -p "$ROOT/build"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name Mogu \
  -module-cache-path "$TMP/mogu-module-cache" \
  "$ROOT"/Sources/Mogu/*.swift -o "$ROOT/build/Mogu-bin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$ROOT/build/Mogu-bin" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s|__HOME__|$ROOT|" -e "s|__NAME__|$APP_NAME|g" -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --sign "${MOGU_SIGN_IDENTITY:--}" "$APP"

echo "できました: $APP"
[[ -x "$ROOT/vendor/llama/llama-server" ]] || echo "推敲を使うときは、先に ./scripts/setup.sh を実行してください"

if (( ${@[(Ie)--install]} )); then
  DEST="$HOME/Applications/$APP_NAME.app"
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true  # 普通に終了させる（書きかけのメモを保存させるため）
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  APP="$DEST"
  echo "入れました: $DEST"
fi
if (( ${@[(Ie)--open]} )); then open "$APP"; fi
