#!/bin/zsh
# Builds a release for download: one Bubble.app for Apple silicon and Intel Macs, signed with the
# hardened runtime, packed in a disk image, plus a SHA-256 checksum people can verify.
#
# With an Apple Developer ID it also has Apple notarise the download, so it opens without warnings:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=bubble ./tools/make-release.sh
# (Create the profile once with: xcrun notarytool store-credentials bubble)
# Without them it signs ad hoc, which is fine for testing but macOS will warn on other Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
OUT=build/release
APP=$OUT/Bubble.app
rm -rf $OUT
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/Info.plist
cp AppIcon.icns $APP/Contents/Resources/

# Same workaround as build.sh for Command Line Tools that ship SwiftBridging twice.
FLAGS=()
DUP=/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap
if [[ -f $DUP && -f ${DUP:h}/module.modulemap ]]; then
  mkdir -p build/vfs
  : > build/vfs/empty.modulemap
  print -r -- "{\"version\":0,\"case-sensitive\":\"false\",\"roots\":[{\"type\":\"file\",\"name\":\"$DUP\",\"external-contents\":\"$PWD/build/vfs/empty.modulemap\"}]}" > build/vfs/overlay.yaml
  FLAGS=(-vfsoverlay build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs/overlay.yaml)
fi

for arch in arm64 x86_64; do
  echo "Building for $arch…"
  swiftc -O -swift-version 5 -target $arch-apple-macos15.0 "${FLAGS[@]}" Sources/*.swift -o $OUT/Bubble-$arch
done
lipo -create -output $APP/Contents/MacOS/Bubble $OUT/Bubble-arm64 $OUT/Bubble-x86_64
rm $OUT/Bubble-arm64 $OUT/Bubble-x86_64

SIGN=(--force --options runtime --entitlements tools/Bubble.entitlements)
if [[ -n ${DEVELOPER_ID:-} ]]; then
  codesign "${SIGN[@]}" --timestamp --sign "$DEVELOPER_ID" $APP
else
  echo "warning: no DEVELOPER_ID, signing ad hoc (macOS will warn when friends open it)"
  codesign "${SIGN[@]}" --sign - $APP
fi
codesign --verify --deep --strict $APP

# Disk image: the app and a shortcut to Applications, so installing is one drag.
STAGE=$OUT/dmg
mkdir -p $STAGE
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
DMG=$OUT/Bubble-$VERSION.dmg
hdiutil create -quiet -volname "Bubble $VERSION" -srcfolder $STAGE -fs HFS+ -format UDZO $DMG
rm -rf $STAGE

if [[ -n ${DEVELOPER_ID:-} ]]; then
  codesign --timestamp --sign "$DEVELOPER_ID" $DMG
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    echo "Sending to Apple for notarisation (a few minutes)…"
    xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple $DMG
    spctl --assess --type open --context context:primary-signature -v $DMG
  fi
fi

( cd $OUT && shasum -a 256 ${DMG:t} > ${DMG:t}.sha256 )
echo "Done: $DMG"
cat $DMG.sha256

# What the website's download section shows.
NOTARIZED=false
[[ -n ${DEVELOPER_ID:-} && -n ${NOTARY_PROFILE:-} ]] && NOTARIZED=true
SHA=$(cut -d' ' -f1 $DMG.sha256)
SIZE=$(stat -f%z $DMG)
cat > docs/release.json <<JSON
{"version": "$VERSION", "url": "https://github.com/HarryNGU/bubble/releases/download/v$VERSION/${DMG:t}", "sha256": "$SHA", "size": $SIZE, "available": ${AVAILABLE:-false}, "notarized": $NOTARIZED, "date": "$(date +%Y-%m-%d)"}
JSON
echo "Updated docs/release.json. Upload ${DMG:t} and ${DMG:t}.sha256 to a GitHub release tagged v$VERSION."
