#!/bin/bash
# Builds the app and packs it into dist/DynamicIsland-<version>.dmg (and a .zip) for a GitHub release.
# The app is self-signed, not notarized: on first launch right-click → Open, or run `xattr -cr DynamicIsland.app`.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' DynamicIsland.app/Contents/Info.plist)"
rm -rf dist && mkdir -p dist/stage
cp -R DynamicIsland.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -volname "DynamicIsland" -srcfolder dist/stage -ov -format UDZO "dist/DynamicIsland-$VERSION.dmg" >/dev/null
ditto -c -k --keepParent DynamicIsland.app "dist/DynamicIsland-$VERSION.zip"
rm -rf dist/stage
echo "✓ dist/DynamicIsland-$VERSION.dmg, dist/DynamicIsland-$VERSION.zip"
