#!/bin/bash
# Install the optional Capture Guard companion, or upgrade it with --upgrade.
# macOS ties its Accessibility approval to the code signature. An upgrade keeps the approval
# only when the build is signed with the same identity as before (see CAPTURE-GUARD.md);
# ad-hoc builds need the permission re-enabled after every upgrade.
set -euo pipefail
cd "$(dirname "$0")"
CAPTURE_APP="$HOME/Applications/LidRunner Capture Guard.app"
CAPTURE_PLIST="$HOME/Library/LaunchAgents/com.anmolbhatia.lidrunner.captureguard.plist"
UPGRADE=0
case "${1:-}" in
  --upgrade) UPGRADE=1 ;;
  "") ;;
  *) printf 'Usage: %s [--upgrade]\n' "$0" >&2; exit 2 ;;
esac
if [[ -d "$CAPTURE_APP" && $UPGRADE -eq 0 ]]; then
  printf '%s\n' 'Capture Guard is already installed. Re-run with --upgrade to replace it.' >&2
  exit 1
fi
./build-capture-guard.sh
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
if [[ -d "$CAPTURE_APP" ]]; then
  launchctl bootout "gui/$(id -u)" "$CAPTURE_PLIST" 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x LidRunnerCaptureGuard >/dev/null || break; sleep 0.5; done
  if pgrep -x LidRunnerCaptureGuard >/dev/null; then
    printf '%s\n' 'Capture Guard is still running. Quit it from its menu-bar icon and run this again.' >&2
    exit 1
  fi
fi
rm -rf "$CAPTURE_APP.new"
ditto 'build/LidRunner Capture Guard.app' "$CAPTURE_APP.new"
rm -rf "$CAPTURE_APP"
mv "$CAPTURE_APP.new" "$CAPTURE_APP"
/usr/bin/python3 - "$CAPTURE_APP" "$CAPTURE_PLIST" <<'PY'
import plistlib, pathlib, sys
app, out = map(pathlib.Path, sys.argv[1:])
config={
 'Label':'com.anmolbhatia.lidrunner.captureguard',
 'ProgramArguments':[str(app/'Contents/MacOS/LidRunnerCaptureGuard')],
 'RunAtLoad':True,
 'KeepAlive':{'SuccessfulExit':False},
 'ThrottleInterval':10,
 'ProcessType':'Interactive',
}
out.write_bytes(plistlib.dumps(config)); out.chmod(0o600)
PY
launchctl bootstrap "gui/$(id -u)" "$CAPTURE_PLIST"
printf 'Installed %s\n' "$CAPTURE_APP"
if [[ $UPGRADE -eq 1 ]]; then
  printf '%s\n' 'If LidRunner shows "Needs Accessibility permission", re-enable Capture Guard in System Settings → Privacy & Security → Accessibility.'
fi
