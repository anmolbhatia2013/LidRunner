#!/bin/bash
# Build LidRunner and install or upgrade it in ~/Applications.
#   ./install.sh                  build, test, install/upgrade LidRunner.app, open it
#   ./install.sh --capture-guard  also install or upgrade the Capture Guard companion
#   ./install.sh --no-launch      don't open LidRunner afterwards
# Never interrupts an active session: stop it first. The privileged helper is not touched;
# LidRunner reinstalls it itself (with the normal administrator prompt) only if it has to.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/LidRunner.app"
BUNDLE_ID="com.anmolbhatia.lidrunner.app"
STATUS="/Library/Application Support/LidRunner/status.json"
WITH_GUARD=0; LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --capture-guard) WITH_GUARD=1 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

phase="$(/usr/bin/plutil -extract phase raw -o - "$STATUS" 2>/dev/null || true)"
if [[ "$phase" == "active" || "$phase" == "restoring" ]] && pgrep -x LidRunner >/dev/null; then
  printf '%s\n' 'A LidRunner session is active. Stop it (⌘⌥⌃⇧L or Stop session) and run this again.' >&2
  exit 1
fi

./build.sh

if pgrep -x LidRunner >/dev/null; then
  printf '%s\n' 'Quitting the running LidRunner…'
  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x LidRunner >/dev/null || break; sleep 0.5; done
  if pgrep -x LidRunner >/dev/null; then
    printf '%s\n' 'LidRunner is still running. Quit it from its menu-bar icon and run this again.' >&2
    exit 1
  fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP.new"
ditto build/LidRunner.app "$APP.new"
rm -rf "$APP"
mv "$APP.new" "$APP"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
printf 'Installed LidRunner %s at %s\n' "$version" "$APP"

if [[ $WITH_GUARD -eq 1 ]]; then
  if [[ -d "$HOME/Applications/LidRunner Capture Guard.app" ]]; then ./install-capture-guard.sh --upgrade
  else ./install-capture-guard.sh; fi
fi

if [[ $LAUNCH -eq 1 ]]; then open "$APP"; fi
