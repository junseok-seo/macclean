#!/bin/zsh
# MacClean.app 과 설치용 DMG를 만든다.
#   ./scripts/build.sh            → dist/MacClean.app, dist/MacClean-<버전>.dmg
#   ./scripts/build.sh --install  → 위 작업 후 /Applications 에 설치
set -euo pipefail

VERSION="1.0.0"
BUILD="$(date +%Y%m%d%H%M)"
ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
APP="$DIST/MacClean.app"
WORK="$ROOT/.build/package"

cd "$ROOT"
echo "▸ 릴리스 빌드"
swift build -c release --product MacClean
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ 앱 번들 구성"
rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"
cp "$BIN_DIR/MacClean" "$APP/Contents/MacOS/MacClean"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" scripts/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 아이콘 생성"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$WORK/icon_1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ 서명 (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

echo "▸ DMG 생성"
DMG="$DIST/MacClean-$VERSION.dmg"
STAGE="$WORK/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacClean" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✓ $APP"
echo "✓ $DMG"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ /Applications 에 설치"
  osascript -e 'tell application "MacClean" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/MacClean.app
  cp -R "$APP" /Applications/
  echo "✓ /Applications/MacClean.app"
fi
