#!/bin/bash
# Builds dist/PingInfoView.app (Apple silicon + Intel, macOS 13+), a DMG, and an installer package.
#
# Optional signing (ad-hoc signing is used when these are unset):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)"
#   NOTARY_PROFILE="profile-name"   # created with: xcrun notarytool store-credentials
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BRAND="$ROOT/Sources/PingInfoView/Brand.swift"
brand() {
  local value
  value="$(sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$BRAND" | head -n 1)"
  if [[ -z "$value" ]]; then
    echo "Could not read '$1' from Brand.swift." >&2
    exit 1
  fi
  printf '%s' "$value"
}

APP_NAME="$(brand appName)"
VERSION="$(brand version)"
BUILD="$(brand build)"
BUNDLE_ID="$(brand bundleIdentifier)"
AUTHOR="$(brand author)"
WEBSITE="$(brand website)"
EMAIL="$(brand email)"
COPYRIGHT="$(brand copyright)"
MIN_MACOS="13.0"

TESTING_PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
TEST_FLAGS=()
if [[ -d "$TESTING_PLUGINS" ]]; then
  TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

echo "== Testing $APP_NAME $VERSION ($BUILD)"
swift test "${TEST_FLAGS[@]}"

echo "== Building universal release binary"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
for arch in arm64 x86_64; do
  if ! lipo "$BIN" -verify_arch "$arch"; then
    echo "The binary is missing $arch." >&2
    exit 1
  fi
done

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

swift "$ROOT/scripts/make-icon.swift" "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>CFBundleGetInfoString</key>
  <string>$APP_NAME $VERSION by $AUTHOR, $WEBSITE</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
    <string>x86_64</string>
  </array>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT · $WEBSITE · $EMAIL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>$APP_NAME contacts hosts on your network to measure whether they respond.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Host List</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.plain-text</string>
        <string>public.text</string>
        <string>public.comma-separated-values-text</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF
plutil -lint "$PLIST"
check_plist() {
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST")"
  if [[ "$actual" != "$2" ]]; then
    echo "Info.plist $1 is '$actual', expected '$2'." >&2
    exit 1
  fi
}
check_plist CFBundleIdentifier "$BUNDLE_ID"
check_plist CFBundleShortVersionString "$VERSION"
check_plist CFBundleVersion "$BUILD"
check_plist LSMinimumSystemVersion "$MIN_MACOS"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== Signing app"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$1"
  fi
}

if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  ZIP="$DIST/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

echo "== Building DMG"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.md" "$STAGE/README.md"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  notarize "$DMG"
fi

echo "== Building installer package"
WORK="$DIST/pkgwork"
PKGROOT="$WORK/root"
mkdir -p "$PKGROOT/Applications" "$WORK/resources"
cp -R "$APP" "$PKGROOT/Applications/"
COMPONENTS="$WORK/components.plist"
pkgbuild --analyze --root "$PKGROOT" "$COMPONENTS" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENTS"
plutil -replace 0.BundleOverwriteAction -string upgrade "$COMPONENTS"
pkgbuild \
  --quiet \
  --root "$PKGROOT" \
  --component-plist "$COMPONENTS" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --install-location / \
  "$WORK/$APP_NAME-component.pkg"

cp "$ROOT/LICENSE" "$WORK/resources/LICENSE.txt"
cat > "$WORK/resources/welcome.html" <<EOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"></head>
<body style="font-family: -apple-system, Helvetica; font-size: 13px;">
<h2>$APP_NAME $VERSION</h2>
<p>Ping many hosts and watch the results in one table. Runs natively on Apple silicon and Intel Macs with macOS $MIN_MACOS or later.</p>
<p>$APP_NAME will be installed in your Applications folder.</p>
<p><b>Author:</b> $AUTHOR<br>
<b>Website:</b> <a href="https://$WEBSITE">$WEBSITE</a><br>
<b>Email:</b> <a href="mailto:$EMAIL">$EMAIL</a></p>
<p>$COPYRIGHT</p>
</body></html>
EOF

cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$APP_NAME $VERSION</title>
  <organization>$BUNDLE_ID</organization>
  <welcome file="welcome.html" mime-type="text/html"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <volume-check>
    <allowed-os-versions>
      <os-version min="$MIN_MACOS"/>
    </allowed-os-versions>
  </volume-check>
  <choices-outline>
    <line choice="default">
      <line choice="$BUNDLE_ID"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$BUNDLE_ID" visible="false">
    <pkg-ref id="$BUNDLE_ID"/>
  </choice>
  <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">$APP_NAME-component.pkg</pkg-ref>
</installer-gui-script>
EOF

PKG="$DIST/$APP_NAME-$VERSION.pkg"
SIGN_PKG=()
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  SIGN_PKG=(--sign "$INSTALLER_IDENTITY" --timestamp)
fi
productbuild \
  --quiet \
  --distribution "$WORK/distribution.xml" \
  --resources "$WORK/resources" \
  --package-path "$WORK" \
  "${SIGN_PKG[@]+"${SIGN_PKG[@]}"}" \
  "$PKG"
rm -rf "$WORK"
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  notarize "$PKG"
fi

(cd "$DIST" && shasum -a 256 "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION.pkg" > SHA256SUMS.txt)

echo
echo "$APP_NAME $VERSION ($BUILD) by $AUTHOR · $WEBSITE · $EMAIL"
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME") · macOS $MIN_MACOS or later"
echo "  $APP"
echo "  $DMG"
echo "  $PKG"
echo "  $DIST/SHA256SUMS.txt"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "  Signed ad-hoc. Set SIGN_IDENTITY, INSTALLER_IDENTITY, and NOTARY_PROFILE for Developer ID signing and notarization."
fi
