#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-$PWD/build/Kadraj.app}"
EXT="$APP/Contents/PlugIns/Kadraj Safari.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/Video.js Resources/Kadraj.icns "$APP/Contents/Resources/"
cp SafariExtensionHost/Info.plist "$EXT/Contents/"
cp SafariExtension/* "$EXT/Contents/Resources/"
ARCHITECTURE="$(uname -m)"
xcrun swiftc -swift-version 5 -target "$ARCHITECTURE-apple-macosx14.0" \
  -module-cache-path "$PWD/build/ModuleCache" -parse-as-library -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain SafariExtensionHost/SafariWebExtensionHandler.swift \
  -o "$EXT/Contents/MacOS/KadrajSafari"
codesign --force --sign - --entitlements SafariExtensionHost/Sandbox.plist "$EXT"
xcrun swiftc -swift-version 5 -target "$ARCHITECTURE-apple-macosx14.0" \
  -module-cache-path "$PWD/build/ModuleCache" Sources/*.swift -o "$APP/Contents/MacOS/Kadraj"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/Kadraj" --self-check
