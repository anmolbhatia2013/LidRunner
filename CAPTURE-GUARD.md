# Automatic screenshot recovery

LidRunner Capture Guard is a companion process that automatically re-centers a window when macOS marks it as being shared for remote control. It watches for a new sharing session, a changed window position/size, or changed display geometry, and waits for the window to settle before adjusting it. This automates the window-position recovery discovered with Calculator.

It is installed separately so updating or quitting it cannot stop an active LidRunner power session. Your existing ⌘⌥⌃⇧L shortcut remains unchanged.

## Setup and use

1. For a first installation, run `./install-capture-guard.sh` from this repository. It builds the companion, installs it at `~/Applications/LidRunner Capture Guard.app`, and registers its user LaunchAgent. Open that app if needed.
2. Choose **Open Accessibility Settings** and enable **LidRunner Capture Guard**. On this macOS 27 build, the destination is named **Device Control and Data Access**. This is a one-time macOS permission; the app cannot grant it itself.
3. Start LidRunner normally and close the lid. Capture Guard activates only while the lid is closed and fresh LidRunner diagnostics show an active sleep override.
4. Start controlling an app remotely. Its shared window is centered automatically after roughly two seconds of stable geometry. Further screenshots should be taken after recovery has settled.

The helper starts at login through `~/Library/LaunchAgents/com.anmolbhatia.lidrunner.captureguard.plist`. Its menu-bar window icon has an **Automatic screenshot recovery** toggle and **Quit Capture Guard**. Neither stops LidRunner or ChatGPT. Successful manual quit stays quit until the next login or manual launch; unexpected crashes are restarted by launchd.

## Scope

The helper uses Apple's Accessibility window-position API. It reads window geometry and sharing controls in window chrome, not document contents. It does not request screen-recording permission, take or save screenshots, send data, type into apps, click document buttons, activate other apps, resize documents, or change authentication. ChatGPT's own windows, hidden apps, minimized windows, full-screen windows and non-standard windows are excluded.

Currently the sharing detector recognizes the English macOS **Window sharing** menu button, which was observed in the actual failing app. Apps or language settings that expose different accessibility chrome may not be recognized. A shared window being moved or resized is re-centered after it settles. Larger-than-display windows are not resized, so their entire contents may still not fit. Repeated failures are rate limited.

The helper stops moving windows when the lid opens, the session stops, diagnostics become stale, Accessibility is unavailable, or its toggle is disabled. Permission can be revoked in System Settings → Privacy & Security → Accessibility.

A successful position readback is not proof of a complete screenshot. Check live captures after installing and after macOS/ChatGPT updates. The helper automates a specific observed recovery; it does not patch ChatGPT's capture implementation or guarantee that every app or rendering issue is repaired.

## Development and diagnostics

- Build and policy checks: `./build-capture-guard.sh`
- First installation: `./install-capture-guard.sh`
- Status: `~/Library/Application Support/LidRunner/capture-guard.json`
- Sources: `Sources/CaptureGuard.swift`, `Sources/CapturePolicy.swift`
- Tests: `Tests/CapturePolicyTests.swift`

The status file reports permission, lid/session eligibility, shared-window count, repair count, errors, and the last position change. It contains no window titles or document content. The current build has 20 passing checks covering stale/expired eligibility, open-lid inactivity, disabled recovery, negative screen origins, offscreen windows, oversized windows, missing displays, rounding tolerance, and the actual AXTitle/AXDescription sharing-label regression.

Use `./uninstall.sh` to remove both LidRunner and its companion after stopping and quitting LidRunner. To remove only this companion, boot out its exact LaunchAgent, remove that plist and the Capture Guard app, then remove its Accessibility entry in System Settings. Existing diagnostics may be retained.

References: [Apple Accessibility APIs](https://developer.apple.com/documentation/applicationservices/axuielement_h), [Apple display configuration notifications](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification).

## Verified on September 24, 2026

Installed and running on the M3 Pro / macOS 27.2 host with Accessibility approved. A deliberate Calculator move to the bottom-right changed its frame origin to (1054, 709); the companion automatically returned it to (545, 371) at the original 674 × 408-point size. No manual Center command was used in that test. The resulting screenshot was complete. A bottom-row angular-unit control worked and was restored to degrees, with result 437 retained. Opening and closing the history sidebar exercised automatic recovery after size changes; the expanded screenshot was also complete. These checks ran with the lid closed and battery power, using Remote.

The initial temporary-signature build required re-adding its permission after changing signing identity. A later build signed with a stable Apple Development certificate retained Accessibility trust across a tested update. Public checkouts use ad-hoc signing by default; optionally set `LIDRUNNER_SIGNING_IDENTITY` to your own local signing identity, or store that identity in the ignored `capture-signing-identity.txt` file. No signing certificate or private key is included. Use the same signing identity for future updates; changing it can require re-approval.

The observed recovery is now automatic and installed persistently. It remains a workaround for the tested window-position issue; arbitrary apps, future OS releases and all capture failures are not verified. The original machine-local evidence logs are intentionally excluded from this public repository.
