#!/bin/zsh
# テストを実行する（SwiftPM を使わず、XCTest のバンドルを直接作って動かす）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
PLATFORM="$(xcrun --show-sdk-platform-path)"
BUNDLE="$ROOT/build/FudeTests.xctest"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
# アプリの入口（App.swift）以外の部品とテストを、まとめて1つのバンドルにする。
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name FudeTests \
  -module-cache-path "$TMP/fude-module-cache" \
  -F "$PLATFORM/Developer/Library/Frameworks" -I "$PLATFORM/Developer/usr/lib" \
  -L "$PLATFORM/Developer/usr/lib" -framework XCTest -lXCTestSwiftSupport \
  -Xlinker -rpath -Xlinker "$PLATFORM/Developer/Library/Frameworks" -Xlinker -rpath -Xlinker "$PLATFORM/Developer/usr/lib" \
  -emit-library -Xlinker -bundle \
  $(ls "$ROOT"/Sources/Fude/*.swift | grep -v /App.swift) "$ROOT"/Tests/FudeTests/*.swift \
  -o "$BUNDLE/Contents/MacOS/FudeTests"
xcrun xctest "$BUNDLE"
