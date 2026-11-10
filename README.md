# LidRunner

A macOS menu-bar app for time-limited closed-lid work sessions on a MacBook, on charger or battery. Keep local work running with optional app keep-alive and agent integrations for ChatGPT/Codex, Claude, Gemini, and Antigravity.

![LidRunner idle, light](docs/screenshots/idle-light.png)

> **Experimental power-management utility.** Closed-lid operation can consume battery and generate heat. Keep the Mac ventilated and stop the session before putting it in a bag. An active power session is not proof that remote access, screenshots, or computer control will work.

## Features

- Manual 1-, 2-, 4-, or 8-hour sessions, with a menu-bar countdown.
- **Command–Option–Control–Shift–L** (⌘⌥⌃⇧L) starts an eight-hour session or stops the current session.
- A bounded privileged helper restores normal sleep on expiry, app exit, stale heartbeat, low battery, or serious thermal pressure.
- Optional keep-alive for installed agent apps, without force-quitting running apps.
- Optional **Capture Guard** companion for a specific shared-window screenshot-clipping workaround.
- Read-only agent skills and lifecycle hooks that report lid and session state.

## Requirements

- A MacBook and Xcode command-line tools (`xcode-select --install`).
- Python 3 for optional agent integration and its tests.
- Administrator approval when the power helper is first installed.

Development testing was performed on Apple silicon with macOS 27.2. The app declares macOS 13.0 as its minimum system version, but compatibility with other macOS releases and Intel Macs has not been verified. Builds are locally signed, not notarized release downloads.

## Build and install

```sh
git clone https://github.com/anmolbhatia2013/LidRunner.git
cd LidRunner
./build.sh
mkdir -p "$HOME/Applications"
if [ -e "$HOME/Applications/LidRunner.app" ]; then
  printf '%s\n' 'Already installed. Stop the session and quit LidRunner before upgrading.'
else
  ditto build/LidRunner.app "$HOME/Applications/LidRunner.app"
  open "$HOME/Applications/LidRunner.app"
fi
```

`./build.sh` compiles the app and helper, runs the power-policy tests, and verifies their ad-hoc signatures. Use `./build.sh --build-only` to skip tests. Build output is kept in `build/` and is not committed.

The copy command is intended for a first installation. Before replacing an existing installation, stop its session and quit the app.

## Use

1. Open LidRunner and select a session length, or use **⌘⌥⌃⇧L** for eight hours.
2. On first use, approve the normal macOS administrator prompt to install the narrowly scoped helper. No password is stored.
3. Wait for **Session active** before closing the lid.
4. Choose **Stop session** or press the shortcut again to restore normal sleep early.

Closing the app window does not stop the session; quitting the menu-bar app does. Login launch can be controlled from the app's menu. Opening the app does not automatically start a power session.

Keep-alive preferences appear for installed apps. ChatGPT may be opened during a session even if it was initially closed; other supported apps are reopened only if they were seen running earlier in that session. Retries use a 15-second debounce, at least 60 seconds between attempts, and a three-attempt cap. No app is signed in or granted permissions automatically.

## Safety and recovery

- Changes only `pmset -a disablesleep`, and requires its initial value to be zero. It does not change sleep timers, screen locking, FileVault, network settings, or app permissions.
- The root-owned helper accepts only bounded session requests from the administrator-configured user and fixed paths, not arbitrary commands.
- A root-owned journal is written before changing sleep. A restarted helper restores normal sleep instead of resuming a prior session.
- The helper checks every two seconds and restores sleep on expiry, app-process loss, a missing/stale heartbeat (20 seconds), battery at or below 15% while unplugged, unavailable battery readings while unplugged, or serious/critical thermal pressure.
- Manual sleep may be inhibited during a session. Stop LidRunner first.
- Recovery depends on macOS and launchd remaining operational. This is not a hardware-level safety guarantee.

Emergency restoration in Terminal:

```sh
sudo /usr/bin/pmset -a disablesleep 0
```

## Remote access and screenshot limitations

LidRunner provides no remote-access service. Use your agent's existing authenticated remote connection and its normal permission controls. For unattended ChatGPT computer use after locking, use the app's official **Locked use** setting where available. LidRunner does not bypass locking or permission prompts.

A sleeping or powered-off Mac cannot be revived through LidRunner. Internet loss, session expiry, battery/thermal cutoff, or an unavailable agent app can interrupt remote work.

Apple's standard closed-display configuration uses power, an external display, and external input devices. LidRunner's software-only approach relies on the `disablesleep` setting, which is not documented in the local `pmset` manual and may change in future macOS versions. It installs no virtual display.

If an app screenshot becomes partly blank after a lid/display transition, its **Window → Center** command may help. This was observed with Calculator, not established as a universal fix. The optional [Capture Guard companion](CAPTURE-GUARD.md) automates a narrowly scoped version of that workaround.

## Agent integrations

See [agents/README.md](agents/README.md) for the shared skill and plugin, installation, tests, hook behavior, and removal. Installing agent integrations is separate from building the macOS app and can modify the selected agent's user-level configuration.

## Tests and verification boundary

```sh
# Build and run power-policy checks
./build.sh

# Build and run Capture Guard policy checks
./build-capture-guard.sh

# Read-only agent unit tests; no model request
python3 agents/tests/test_closed_lid_skill.py
```

Historical local testing included short charger/battery lid-close sessions, background execution, app input, a phone-to-host ChatGPT Remote interaction, and Calculator screenshot recovery. Those observations are not a reliability guarantee or proof of compatibility with arbitrary apps. Long overnight runs, reboot/crash recovery, low-battery and high-temperature cutoffs, and closed-lid Claude/Antigravity remote transport have not all been physically exercised.

Local evidence logs and installation records are intentionally excluded from this repository. Automated policy tests do not substitute for real-device verification.

## Privacy and local files

The macOS app sends no network requests. Diagnostics describe power/session/display state, not document contents, task prompts, or screenshots.

- App source: `Sources/`
- Policy tests: `Tests/`
- User diagnostics: `~/Library/Application Support/LidRunner/`
- Root request/journal: `/Library/Application Support/LidRunner/`
- Privileged helper: `/Library/PrivilegedHelperTools/com.anmolbhatia.lidrunner`
- Launch daemon: `/Library/LaunchDaemons/com.anmolbhatia.lidrunner.plist`

Builds, evidence logs, old backups, local registration records, and machine-specific signing settings are ignored by Git. See [IMPLEMENTATION.md](IMPLEMENTATION.md) for process boundaries.

## Remove

Disable **Open at Login**, stop the session, and quit LidRunner. The uninstaller unconditionally restores `disablesleep` to zero, so do not run it while another utility relies on that override. Then run:

```sh
./uninstall.sh
```

The script restores sleep and removes LidRunner's installed helper, daemon, app, and Capture Guard companion. Source and diagnostic history are retained. Agent integrations have separate removal instructions in [agents/README.md](agents/README.md).

## References

- [Apple: using an external display with a closed Mac laptop](https://support.apple.com/en-au/102501)
- [ChatGPT settings](https://learn.chatgpt.com/docs/reference/settings)
- [ChatGPT Computer Use](https://learn.chatgpt.com/docs/computer-use)
