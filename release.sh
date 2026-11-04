#!/bin/zsh
set -eu
cd "$(dirname "$0")"
MODE="${1:---preview}"
if [[ "$MODE" != --preview && "$MODE" != --release ]]; then echo 'Use --preview or --release'; exit 2; fi
if [[ "$MODE" == --release && ( -z "${SIGN_IDENTITY:-}" || -z "${NOTARY_PROFILE:-}" ) ]]; then
  echo 'Public release requires SIGN_IDENTITY (Developer ID Application) and NOTARY_PROFILE (notarytool keychain profile).'; exit 1
fi
zsh build.sh
python3 test-usage.py
node test-harness-labels.mjs
APP='build/提示词工作台.app'
mkdir -p dist
if [[ "$MODE" == --release ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  ditto -c -k --keepParent "$APP" dist/notarization-upload.zip
  xcrun notarytool submit dist/notarization-upload.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  ZIP='dist/PromptDesk-1.5.0-macOS-universal.zip'
else
  ZIP='dist/PromptDesk-1.5.0-macOS-universal-PREVIEW-not-notarized.zip'
fi
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/PromptDesk" -verify_arch arm64 x86_64
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "$ZIP"
