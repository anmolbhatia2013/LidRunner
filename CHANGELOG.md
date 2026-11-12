# Changelog

Versions are the LidRunner app's. The agent plugin and Capture Guard carry their own version numbers, noted where they changed.

## 1.5 — 12 November 2026

### Added
- **Phone remote.** A page on your phone, served by LidRunner over your Wi-Fi or Tailscale, that shows the Mac's state and starts or stops sessions. Off by default, paired by QR code, every command signed. See the README's [Phone remote](README.md#phone-remote) section for what it can do and its security model.
- **Stay reachable on charger.** While plugged in, the Mac stays awake with the lid closed so the phone remote and remote tools can reach it. The privileged helper (protocol 3) ends the hold two minutes after the charger is disconnected. Needs a one-time administrator approval.
- **RustDesk** as a built-in app, with a shortcut on the phone page to open it. Capture Guard (1.3) leaves its windows alone.
- **Add app…** keeps any other installed app available during sessions.
- LidRunner detects when the macOS firewall is blocking the phone remote and says so.
- `status.py` reports `session_kind` (`timed` or `charger`) and RustDesk. Plugin 1.4.0.

### Changed
- `build.sh` signs with a stable identity when one is configured, so macOS keeps the firewall approval across upgrades.
- The window's "Agents" card is now "Apps".
- `uninstall.sh` removes the phone-remote pairing secret.

### Not yet verified
- Use from a physical phone, over Tailscale, and with the lid closed.
- Stay reachable: the updated helper has not been installed or run.

## 1.4 — 11 November 2026

### Fixed
- **Sessions could end early with "LidRunner heartbeat lost" while a menu was open.** The heartbeat ran on a timer that pauses during menu tracking, so leaving the menu-bar menu or the session-length picker open for 20 seconds made the helper restore sleep. The heartbeat now runs on its own queue, the tick timer runs in common run-loop modes, and the app opts out of App Nap during a session. See [IMPLEMENTATION.md](IMPLEMENTATION.md#heartbeat-and-run-loop-fix-14).
- A start that failed while the window was closed (for example from the shortcut) failed silently. The window now opens to show the reason.
- Start errors stayed on screen indefinitely. They now clear after two minutes or when a session starts.
- The hook's per-session cache grew without limit (thousands of files within days on a Mac running headless agents). State for sessions idle longer than a day is now pruned. Plugin 1.3.3.

### Added
- `install.sh`: build, test, and install or upgrade in one step, refusing to interrupt an active session. `install-capture-guard.sh --upgrade` upgrades the companion.
- Capture Guard status in the main window: running, paused, missing its Accessibility permission, or not running, with a button to fix the last two.
- A notification when a session ends on its own (time limit, battery, heat, lost heartbeat), with the reason.
- The menu-bar menu shows the live session state, the remembered length, and the shortcut.
- GitHub Actions CI: both builds, all policy checks, and the agent tests.
- `--test-menu-hold <seconds>` (with `--start-verification`) as a regression check for the heartbeat fix.

### Changed
- ⌘⌥⌃⇧L starts a session of the remembered length instead of always eight hours. The default is still eight.
- The previous session's outcome is described in plain language ("Last session stopped at 15% battery.").
- Idle diagnostics are written far less often: the sampling history records every sample during a session, otherwise only changes plus one a minute. Capture Guard (1.2) writes its status on change or every three seconds.
- Launching a second copy brings the running one forward and exits.
- LidRunner no longer opens its window when macOS starts it at login.
- `agents/e2e.sh` no longer needs a `timeout` command.

## 1.3 — 6 November 2026
- Redesigned window: session card with time-remaining bar and power, lid, network and thermal readouts; an agents card with per-app state, phone-remote hints, integration badges and keep-alive switches.
- Session-length picker (1, 2, 4 or 8 hours, remembered).
- `--snapshot` renders the window to a PNG for design review without touching a running copy.
- Labelled lid simulation (`LIDRUNNER_SIMULATE_LID`) and `agents/e2e.sh` for testing agent integrations with the lid open.

## 1.2 — 6 November 2026
- Claude, Gemini and Antigravity support alongside ChatGPT/Codex: per-app keep-alive (apps other than ChatGPT are only reopened if they were running earlier in the session), and Capture Guard skips every agent app's own windows.
- One shared `closed-lid-mode` skill and hook script, packaged as a Claude Code plugin and an Antigravity plugin and installable as a Codex skill.

## 1.1 — 24 September 2026
- Phone-remote support: network status and optional ChatGPT keep-alive during a session.
- Capture Guard companion for automatic window re-centring.

## 1.0 — 24 September 2026
- Bounded closed-lid sessions with a privileged helper that restores sleep on expiry, app exit, lost heartbeat, low battery, or thermal pressure. Global shortcut ⌘⌥⌃⇧L.
