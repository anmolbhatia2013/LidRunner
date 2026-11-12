#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/LidRunner.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O Sources/Core.swift Sources/Guardian.swift -o "$APP/Contents/Resources/LidRunnerGuardian" -framework IOKit -framework CoreGraphics
xcrun swiftc -swift-version 5 -O Sources/Core.swift Sources/RemoteProtocol.swift Sources/RemoteServer.swift Sources/UI.swift Sources/App.swift Sources/AppRemote.swift -o "$APP/Contents/MacOS/LidRunner" -framework AppKit -framework IOKit -framework CoreGraphics -framework Carbon -framework ServiceManagement -framework Network -framework SystemConfiguration -framework CryptoKit -framework CoreImage -framework UserNotifications
cp Sources/remote.html "$APP/Contents/Resources/remote.html"
cp agents/plugin/assets/icon.png "$APP/Contents/Resources/remote-icon.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.anmolbhatia.lidrunner.app</string>
<key>CFBundleName</key><string>LidRunner</string>
<key>CFBundleExecutable</key><string>LidRunner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc by default. With a stable identity (LIDRUNNER_SIGNING_IDENTITY, or the fingerprint in
# capture-signing-identity.txt) the macOS firewall keeps its approval of Phone remote across
# upgrades; ad-hoc builds are asked again after every rebuild.
SIGNING_IDENTITY="${LIDRUNNER_SIGNING_IDENTITY:-$(cat capture-signing-identity.txt 2>/dev/null || printf '%s' -)}"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP/Contents/Resources/LidRunnerGuardian"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
if [[ "${1:-}" != "--build-only" ]]; then
  xcrun swiftc -swift-version 5 Sources/Core.swift Sources/RemoteProtocol.swift Tests/PolicyTests.swift -o build/policy-tests -framework IOKit -framework CoreGraphics
  ./build/policy-tests
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
