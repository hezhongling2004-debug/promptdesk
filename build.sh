#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="build/提示词工作台.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Use the bundle icon, never a Finder custom-icon resource fork. Finder custom
# icons can keep a different scale/cache from Dock and Stage Manager.
xattr -cr "$APP"
rm -f "$APP/"$'Icon\r'
for arch in arm64 x86_64; do
  xcrun swiftc -target "$arch-apple-macos14.0" -swift-version 5 -O -parse-as-library Sources/*.swift -o "build/PromptDesk-$arch" -framework SwiftUI -framework AppKit
done
lipo -create build/PromptDesk-arm64 build/PromptDesk-x86_64 -output "$APP/Contents/MacOS/PromptDesk"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.promptdesk.app' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string 提示词工作台' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string PromptDesk' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.5.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1.5.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string NSApplication' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$APP/Contents/Info.plist"
if [[ -f Assets/AppIcon.png ]]; then
  xcrun swift prepare-icon.swift Assets/AppIconArtwork.png Assets/AppIcon.png
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  rm -f "$APP/Contents/Resources/AppIcon.icns"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PromptDeskBrand.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string PromptDeskBrand.icns' "$APP/Contents/Info.plist"
fi
cp Assets/usage-scan.py "$APP/Contents/Resources/usage-scan.py"
cp Assets/harness-labels.cjs "$APP/Contents/Resources/harness-labels.cjs"
codesign --force --deep --sign - "$APP"
"$APP/Contents/MacOS/PromptDesk" --self-test
