#!/bin/sh
# Builds MD2Audio.app (Universal: Apple Silicon + Intel) and packages it for sharing.
#
#   ./build_app.sh                      # build/MD2Audio.app + dist/MD2Audio-<version>.dmg/.zip
#
# Optional environment variables:
#   VERSION=1.2                          version shown in Finder/About (default 1.0)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#                                        sign with a Developer ID instead of ad-hoc
#   NOTARY_PROFILE=md2audio              notarize with a keychain profile created by
#                                        `xcrun notarytool store-credentials` (needs SIGN_IDENTITY)
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP=build/MD2Audio.app
DIST=dist
NAME="MD2Audio-$VERSION"

echo "==> Compiling (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MD2Audio"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MD2Audio"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MD2Audio</string>
  <key>CFBundleDisplayName</key><string>MD2Audio</string>
  <key>CFBundleIdentifier</key><string>local.md2audio.app</string>
  <key>CFBundleExecutable</key><string>MD2Audio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Converts Markdown to audio with the macOS system voices.</string>
</dict>
</plist>
PLIST

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing with $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Signing ad-hoc (no Developer ID: recipients must allow the app once, see README)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Packaging"
rm -rf "$DIST" && mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname MD2Audio -srcfolder "$STAGE" -format UDZO -ov "$DIST/$NAME.dmg"
rm -rf "$STAGE"
[ -n "$SIGN_IDENTITY" ] && codesign --force --sign "$SIGN_IDENTITY" "$DIST/$NAME.dmg"

if [ -n "$NOTARY_PROFILE" ] && [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$DIST/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST/$NAME.dmg"
  xcrun stapler staple "$APP"
fi

ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"

echo
echo "App: $(pwd)/$APP"
echo "DMG: $(pwd)/$DIST/$NAME.dmg"
echo "ZIP: $(pwd)/$DIST/$NAME.zip"
