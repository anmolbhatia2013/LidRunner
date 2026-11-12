#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
CAPTURE_APP="$PWD/build/LidRunner Capture Guard.app"
mkdir -p "$CAPTURE_APP/Contents/MacOS"
xcrun swiftc -swift-version 5 Sources/CapturePolicy.swift Tests/CapturePolicyTests.swift -o build/capture-policy-tests -framework CoreGraphics
./build/capture-policy-tests
xcrun swiftc -swift-version 5 -O Sources/Core.swift Sources/CapturePolicy.swift Sources/CaptureGuard.swift -o "$CAPTURE_APP/Contents/MacOS/LidRunnerCaptureGuard" -framework AppKit -framework ApplicationServices -framework IOKit -framework CoreGraphics
cat > "$CAPTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.anmolbhatia.lidrunner.captureguard</string>
<key>CFBundleName</key><string>LidRunner Capture Guard</string>
<key>CFBundleExecutable</key><string>LidRunnerCaptureGuard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
CAPTURE_SIGNING_IDENTITY="${LIDRUNNER_SIGNING_IDENTITY:-$(cat capture-signing-identity.txt 2>/dev/null || printf '%s' -)}"
codesign --force --sign "$CAPTURE_SIGNING_IDENTITY" --timestamp=none "$CAPTURE_APP"
codesign --verify --deep --strict "$CAPTURE_APP"
printf 'Built %s\n' "$CAPTURE_APP"
