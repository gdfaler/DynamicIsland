#!/bin/bash
# Builds DynamicIsland.app from Sources/*.swift (requires Command Line Tools: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="DynamicIsland.app"
BUNDLE_ID="local.dynamicisland"

# If an old instance is running, close it.
if pkill -x DynamicIsland 2>/dev/null; then sleep 1; fi

echo "→ Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/DynamicIsland"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DynamicIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>DynamicIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>The island shows the artwork and position of the current track and controls playback in Music.</string>
</dict>
</plist>
PLIST

# Icon: drop your own icon.png (1024×1024) next to this script; if there's none, draw the default one.
if [ ! -f icon.png ]; then
    echo "→ Drawing the icon…"
    swift MakeIcon.swift icon.png
fi
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Sign with a PERSISTENT self-signed certificate instead of ad-hoc. With ad-hoc the signature (and the permissions
# tied to it: Screen Recording, Automation for Music/Safari) changed on every rebuild, so macOS treated the app as
# new and the permissions "fell off". The certificate lives in a separate keychain and is created once, so from then
# on the signature is stable and permissions survive rebuilds.
SIGN_ID="DynamicIsland Local Signer"
SIGN_KC="$HOME/Library/Keychains/dynamicisland-signing.keychain-db"

if ! security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
    echo "→ Creating the persistent signing identity (one time)…"
    TMP="$(mktemp -d)"
    cat > "$TMP/cert.conf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=DynamicIsland Local Signer
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -config "$TMP/cert.conf" -extensions v3 >/dev/null 2>&1
    # Legacy PKCS12 encryption — otherwise macOS `security import` can't read a bundle from LibreSSL.
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
        -passout pass:island -name "$SIGN_ID" -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1
    # A separate keychain without a partition list — codesign takes the key from it without password prompts.
    security create-keychain -p "" "$SIGN_KC" 2>/dev/null || true
    security set-keychain-settings "$SIGN_KC"
    security unlock-keychain -p "" "$SIGN_KC"
    security import "$TMP/id.p12" -k "$SIGN_KC" -P "island" -A >/dev/null 2>&1
    rm -rf "$TMP"
fi

echo "→ Signing…"
if security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
    security unlock-keychain -p "" "$SIGN_KC" 2>/dev/null || true
    # Pre-authorize codesign to use the key (the keychain password is empty) — otherwise macOS asks for it by hand.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$SIGN_KC" >/dev/null 2>&1 || true
    codesign --force --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP"
else
    echo "  (couldn't create a persistent signature — signing ad-hoc; permissions will then fall off each rebuild)"
    codesign --force --sign - "$APP"
fi

# So Finder shows the new icon right away instead of the cached old one.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "✓ Done: $(pwd)/$APP"
echo "  Launch: open \"$APP\""
