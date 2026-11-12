# Implementation notes

Historical development notes follow. References to `evidence/` describe machine-local records intentionally excluded from the public repository. Session state and installation observations are historical, not claims about the reader's Mac. See the README for current setup and verification limits.

## Process boundaries

The AppKit menu-bar process owns the global Carbon hotkey (key code 37 with Command, Option, Control, Shift), the login item, display/idle assertions, and its UI. The shortcut applies to the whole Mac, so all local Codex tasks benefit from an enabled session. It does not change Codex task state or infer when tasks have completed. Pressing the shortcut again stops the session. Auto-repeat events are not separately registered.

The root launch daemon accepts only JSON session requests from the one administrator-configured user and fixed file paths. It never executes a user-provided command, and user input cannot choose the `pmset` command, helper executable, or restoration value. Reads reject symlink leaves, non-regular files, wrong owners, oversized payloads, stale requests, foreign boot IDs and mismatched heartbeat tokens. Durations are limited to eight hours. No network listener, sudoers grant, password storage or authentication bypass is installed.

Before enabling `disablesleep`, the helper requires its baseline to be zero and persists an active journal. Restoration is zero, preserving the accepted baseline. If someone else's sleep override is already active, the request fails without taking ownership. A restarted helper restores a prior active/restoring journal before processing anything else. The completed token suppresses accidental resumption of a stale request. Sleep recovery is retried on helper launch failure by launchd.

The session deadline is checked against wall time plus a monotonic upper bound. The app sends a heartbeat every two seconds, from a dedicated queue since 1.4 (see below); the daemon stops after a 20-second heartbeat loss, app process exit, low battery, serious/critical thermal state, or deadline. The daemon checks these conditions every two seconds. Closing the app window has no effect; quitting the app requests restoration. ChatGPT process visibility is informational only. A transient missing-process observation must not disable the sleep session.

## Actual evidence

- Host: Apple M3 Pro, macOS 27.2 build 26B5086k.
- Initial revision: successful Swift build and ad-hoc signature verification; 16 policy checks passed.
- Initial revision: app screenshot and one harmless input action succeeded with the lid open.
- Initial revision: administrator-approved five-minute session read back `SleepDisabled = 1` on battery, then automatically restored `SleepDisabled = 0` on expiry. Root ownership and permissions of the helper, launch daemon and journal were checked.
- Final revision: compiled and signature checked. Runtime registration reports `shortcutRegistered = true` for Command-Option-Control-Shift-L, and `loginEnabled = true`.
- Final revision: no simulated crashes, further behavioral tests, or lid-close experiments performed, at the user's request.
- Closed-lid GUI control, charger transitions, locked use, recovery after reboot and prolonged operation remain unverified. Source design and compilation do not establish a numerical probability of success.

## Limits

The power override is a real macOS setting, but `disablesleep` is not documented by the local `pmset` manual. Future macOS behavior can change. Desktop automation separately depends on a usable graphical session, display availability, ChatGPT's permissions and its official Locked use facility. The app does not create virtual displays, defeat locking, approve access requests, or keep a depleted battery alive. Existing caffeinate/assertions belonging to other apps remain untouched. Recovery requires a functioning macOS/launchd environment.

## Installation completion

The user approved final helper installation. The root-owned configuration reports protocol version 2 and the expected user/path constraints. The final journal reports an active eight-hour session; the app reports the shortcut registered, login enabled, and the actual sleep override enabled. This is installation/readback evidence, not a closed-lid or hotkey-press behavioral test.

## Physical testing update — September 24

See `evidence/verification-summary.json`. Charger and battery physical lid-close tests completed with active override, continuous execution, successful HTTPS and verified app input. A transient missing ChatGPT-process reading caused the first attempt's early stop; that condition was removed. Calculator screenshots were partly blank during the battery test and still partly blank after opening the lid. A later capture investigation found a per-window recovery, documented below. The active global key is now Command-Option-Control-Shift-L; Tailscale retains its existing all-modifier R key.

## Screenshot recovery investigation — September 24

Calculator's Window → Center restored full screenshots after capture became clipped. Sidebar interactions then retained the full image. Closing the lid reproduced the clipping; choosing Center again while still closed on battery restored the entire 1348 × 816 screenshot. A bottom-row angular-unit button in the previously blank area responded, and the original degree mode was restored. The result stayed 437. Fresh diagnostics confirmed lidClosed=true, onCharger=false, phase=active, sleepDisabled=true, and battery=41%.

Window geometry or capture bounds are a plausible cause, not a confirmed internal diagnosis. This is a tested recovery for Calculator, not an automatic correction in LidRunner or a guarantee for other apps. No app restart, display driver installation, authentication changes or power changes were needed. Evidence: `evidence/20260924-screenshot-recovery.json` and the CUA screenshots in the task transcript.

## Remote support revision

Version 1.1 adds local NWPathMonitor network status and an optional in-session ChatGPT application keep-alive. It tolerates a 15-second process absence, uses the normal macOS app launcher with activation disabled, never force-quits a running app, and caps retry attempts. The existing bounded power helper is unchanged. The host's existing authenticated ChatGPT Remote pairing remains the transport. No new listener, account grant, authentication bypass or pairing code is created. Policy checks cover disabled/expired sessions, transient process gaps, a running/launching app, cooldown and retry exhaustion.

The iPhone Remote test passed at 21:19:33 local time on September 24. User-reported iPhone-origin input reached this task, followed immediately by a local command and fresh closed-lid/battery/active-override readback. Evidence: `evidence/20260924-iphone-remote.json`. The app-launch policy has 26 passing combined policy checks; no live forced-quit/relaunch of ChatGPT was attempted because active tasks were running.

## Automatic capture companion

A separately signed Capture Guard app and per-user LaunchAgent now automate the window-centering recovery without restarting the power app. It gates action on a fresh active LidRunner session and the physical closed-lid state, recognizes window-sharing chrome via AXTitle or AXDescription, centers stable shared standard windows and verifies their position readback. It rechecks eligibility immediately before changing a position. Failed moves are bounded; successful moves reset the failure budget. No screen recording or document contents are collected.

20 capture policy tests pass. Live closed-lid battery testing confirmed automatic recovery from a deliberate bottom-right position and window-width changes, complete Calculator captures and working bottom-row input. A stable developer signature retained permission across a tested app update. See `CAPTURE-GUARD.md` for scope, controls, startup and removal.

## Multi-agent revision (1.2)

`Core.swift` defines `agentApps` and `shouldReopenAgentApp`, which adds `seenThisSession`/`launchIfNeverSeen` to the 1.1 gate. `App.swift` keeps one `AgentKeeper` per app; `seenThisSession` resets whenever the session is inactive. The Guardian helper's logic is unchanged and was not reinstalled (no administrator prompt). Capture Guard excludes `agentBundleIDs`.

The hook script is host-agnostic: Codex and Claude Code share the `hookSpecificOutput.additionalContext` contract; Antigravity uses `injectSteps` with `ephemeralMessage` on `PreInvocation`, and its per-turn detection uses the integer `initialNumSteps` (observed live: 1, then 3 on the following turn). Antigravity's `PreToolUse` requires an allow/deny decision, so it is deliberately not registered. Without `--host`, the script behaves as before for Codex, so the existing `~/.codex/hooks.json` command and its trust are untouched.

Live checks on 6 November: Codex app-server (0.162.1) listed the updated skill and reported all four hooks trusted; a headless Claude Code run executed the plugin hook, but a model response was not verified; a headless Antigravity run executed the hook and the model reported the skill and rule loaded. No closed-lid physical test of the Claude or Antigravity paths has been performed.

## Heartbeat and run-loop fix (1.4)

A 1.3 session on 10 November ended after 96 minutes with "LidRunner heartbeat lost" while the helper and the Mac were healthy: the app had stopped sampling for 134 seconds. The cause is that 1.3 drove its heartbeat from `Timer.scheduledTimer`, which only fires in the default run-loop mode. AppKit switches modes while a menu, the session-length pop-up, or a window drag is tracking, so the heartbeat paused for as long as a menu stayed open, and the helper restored sleep after 20 seconds. A scratch experiment confirmed the mechanism (default-mode timer: 0 fires during menu tracking; common-mode timer: fired normally).

1.4 changes three things:

- The tick timer is added to the common run-loop modes, in both LidRunner and Capture Guard.
- `HeartbeatWriter` writes the heartbeat from its own dispatch queue. The main thread reports the current token and stop flag on every tick; the writer keeps going through UI stalls shorter than `mainThreadStallLimit` (ten minutes) and then stops, so a hung app still cannot hold the Mac awake to the deadline. The helper's own deadline, battery, thermal and process-exit checks are unchanged.
- While a session is requested the app holds a `ProcessInfo` user-initiated activity, which opts it out of App Nap and timer throttling.

Verification: `LidRunner --start-verification --test-menu-hold 30` starts a five-minute session and holds the status menu open for 30 seconds. On 11 November the menu stayed open 30.3 seconds, 15 ticks ran during the hold, the heartbeat was never older than 2 seconds, and the session stayed active. The helper binary was not changed or reinstalled.

Other 1.4 behaviour: a second copy of the app hands over to the running one and exits; the shortcut starts the remembered session length; start errors open the window and expire after two minutes; idle sampling writes are throttled (`shouldAppendSample`); Capture Guard writes its status file on change or every three seconds instead of every second; a session that ends on its own posts a local notification (`sessionEndNotice`). All of these decisions are pure functions in `Core.swift` with checks in `Tests/PolicyTests.swift` (67 checks).

## Phone remote, stay reachable, RustDesk (1.5)

**Files.** `RemoteProtocol.swift` holds every rule as a pure function: strict HTTP parsing with small limits, the signed-request check, the nonce cache, the lockout, the address filter and the command parser. `RemoteServer.swift` is the Network.framework listener (one request per connection, eight-second cap, sixteen connections). `AppRemote.swift` is the app side: pairing secret, switches, the pairing window and the request handler. `remote.html` is the page, copied into the app bundle; it carries its own SHA-256/HMAC because `crypto.subtle` is unavailable on plain-HTTP pages. The Swift and JavaScript implementations are tied together by a shared known-answer vector in `Tests/PolicyTests.swift`.

**Why plain HTTP is acceptable here.** There is no certificate a phone would trust for a Mac on a home network, and Tailscale already encrypts its own path. So the design assumes the transport is readable and makes that harmless: the secret never travels (it is delivered by QR code and used only as an HMAC key), every command is bound to its method, path, body, a timestamp within 90 seconds and a single-use nonce, and the command surface is four fixed operations. What remains is status spoofing by an active attacker on the same network, which is documented in the README.

**Pairing and Home Screen apps.** The pairing link carries the secret in its `#fragment`, which browsers do not send to the server. The page keeps the fragment in the address on purpose: iOS gives a Home Screen web app its own storage, so the installed app needs the fragment to pair itself on first launch.

**Firewall.** macOS filters incoming connections per app and exempts loopback, so the app cannot tell from its own listener state that phones are blocked. It therefore connects to its own LAN address every 20 seconds while Phone remote is on; no answer means the firewall (or its pending prompt) is in the way, and the window says so. Verified on 12 November: with LidRunner not yet allowed, an already-allowed server answered on the LAN address and LidRunner did not, and `phoneRemoteBlockedByFirewall` became true.

**Stay reachable (helper protocol 3).** `Request.acOnly` marks a charger-only session. The helper accepts it only on AC power, allows up to seven days instead of eight hours, and ends it with "Charger disconnected" once the charger has been absent for two minutes (`standbyStopReason`). Everything else (heartbeat, process-exit, thermal, the monotonic deadline, restore-on-restart) is unchanged. The app decides when to hold with `standbyAction`: start while plugged in and idle, never touch a session the user started, renew only with the lid open (stopping with the lid closed would put the Mac to sleep). A charger hold takes no display-sleep assertion, posts no notifications, and suspends app keep-alive while the lid is open.

The installed protocol-2 helper keeps working for timed sessions (`(standby ? 3 : 2)...3 ~= installed.version`), so upgrading LidRunner never forces an administrator prompt; only enabling Stay reachable does. If that approval is declined the option switches itself off rather than prompting again every 30 seconds. A timed session requested while a charger hold is active is a handover (stop, then start): safe with the lid open, refused remotely when the lid is closed.

**Apps.** RustDesk (`com.carriez.rustdesk`) is a built-in row; Capture Guard never moves its windows. "Add app…" stores `[name, bundleID]` pairs in `customApps`; `customApps(from:)` validates them and gives them the cautious keep-alive rule. This is how an app LidRunner has never heard of is supported.

**Signing.** `build.sh` signs with `LIDRUNNER_SIGNING_IDENTITY` or the fingerprint in `capture-signing-identity.txt` when present, otherwise ad-hoc. The firewall's decision is tied to the signature, so a stable identity keeps Phone remote allowed across upgrades.
