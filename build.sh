#!/bin/zsh
# Builds Bubble.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Bubble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/"

# Some Command Line Tools releases ship SwiftBridging twice (module.modulemap and
# bridging.modulemap), which breaks every compile. Hide the duplicate with a VFS overlay.
FLAGS=()
DUP=/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap
if [[ -f $DUP && -f ${DUP:h}/module.modulemap ]]; then
  mkdir -p build/vfs
  : > build/vfs/empty.modulemap
  print -r -- "{\"version\":0,\"case-sensitive\":\"false\",\"roots\":[{\"type\":\"file\",\"name\":\"$DUP\",\"external-contents\":\"$PWD/build/vfs/empty.modulemap\"}]}" > build/vfs/overlay.yaml
  FLAGS=(-vfsoverlay build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs/overlay.yaml)
fi

swiftc -O -swift-version 5 -target arm64-apple-macos15.0 "${FLAGS[@]}" \
  Sources/*.swift -o "$APP/Contents/MacOS/Bubble"

# Sign with the local "Bubble Local Signing" certificate (login keychain) so macOS sees the
# same app on every rebuild and keeps its Screen Recording, camera and mic permissions.
# Falls back to ad-hoc signing if the certificate isn't there.
IDENTITY=$(security find-identity -p codesigning | awk '/"Bubble Local Signing"/ {print $2; exit}')
if [[ -n $IDENTITY ]]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "warning: 'Bubble Local Signing' certificate not found; signing ad-hoc (permissions may reset)"
  codesign --force --deep --sign - -r='designated => identifier "io.github.bubble-recorder"' "$APP"
fi

mkdir -p ~/Applications
rm -rf ~/Applications/Bubble.app
mv "$APP" ~/Applications/  # keep a single copy so macOS permissions stay attached to one app
echo "Installed ~/Applications/Bubble.app"
