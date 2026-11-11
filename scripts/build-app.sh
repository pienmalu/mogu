#!/bin/zsh
# アプリを作る。使い方: ./scripts/build-app.sh [--open]
# アプリ名と bundle ID はこの2行だけで決まる（Info.plist とコードはここから受け取る）。
APP_NAME="${APP_NAME:-Fude}"
BUNDLE_ID="${BUNDLE_ID:-dev.haruka.fude}"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/$APP_NAME.app"
TMP="${TMPDIR:-/tmp}"

mkdir -p "$ROOT/build"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name Fude \
  -module-cache-path "$TMP/fude-module-cache" \
  "$ROOT"/Sources/Fude/*.swift -o "$ROOT/build/Fude-bin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$ROOT/build/Fude-bin" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s|__HOME__|$ROOT|" -e "s|__NAME__|$APP_NAME|g" -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --sign "${FUDE_SIGN_IDENTITY:--}" "$APP"

echo "できました: $APP"
[[ -x "$ROOT/vendor/llama/llama-server" ]] || echo "推敲を使うときは、先に ./scripts/setup.sh を実行してください"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
