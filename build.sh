#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/LidRunner.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O Sources/Core.swift Sources/Guardian.swift -o "$APP/Contents/Resources/LidRunnerGuardian" -framework IOKit -framework CoreGraphics
xcrun swiftc -swift-version 5 -O Sources/Core.swift Sources/UI.swift Sources/App.swift -o "$APP/Contents/MacOS/LidRunner" -framework AppKit -framework IOKit -framework CoreGraphics -framework Carbon -framework ServiceManagement -framework Network
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.anmolbhatia.lidrunner.app</string>
<key>CFBundleName</key><string>LidRunner</string>
<key>CFBundleExecutable</key><string>LidRunner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/LidRunnerGuardian"
codesign --force --sign - "$APP"
if [[ "${1:-}" != "--build-only" ]]; then
  xcrun swiftc -swift-version 5 Sources/Core.swift Tests/PolicyTests.swift -o build/policy-tests -framework IOKit -framework CoreGraphics
  ./build/policy-tests
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
