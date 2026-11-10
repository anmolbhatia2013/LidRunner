#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
CAPTURE_APP="$HOME/Applications/LidRunner Capture Guard.app"
CAPTURE_PLIST="$HOME/Library/LaunchAgents/com.anmolbhatia.lidrunner.captureguard.plist"
if [[ -d "$CAPTURE_APP" ]]; then
  printf '%s\n' 'Capture Guard already installed; preserve its permission identity and stop it before an intentional upgrade.' >&2
  exit 1
fi
./build-capture-guard.sh
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
ditto 'build/LidRunner Capture Guard.app' "$CAPTURE_APP"
python3 - "$CAPTURE_APP" "$CAPTURE_PLIST" <<'PY'
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
