#!/bin/bash
set -euo pipefail
if pgrep -x LidRunner >/dev/null; then
  printf '%s\n' 'Stop the session and quit LidRunner before uninstalling.' >&2
  exit 1
fi
sudo /usr/bin/pmset -a disablesleep 0
sudo /bin/launchctl bootout system /Library/LaunchDaemons/com.anmolbhatia.lidrunner.plist 2>/dev/null || true
sudo /bin/rm -f /Library/LaunchDaemons/com.anmolbhatia.lidrunner.plist /Library/PrivilegedHelperTools/com.anmolbhatia.lidrunner
sudo /bin/rm -f '/Library/Application Support/LidRunner/config.json' '/Library/Application Support/LidRunner/request.json' '/Library/Application Support/LidRunner/status.json'
sudo /bin/rmdir '/Library/Application Support/LidRunner' 2>/dev/null || true
/bin/rm -rf "$HOME/Applications/LidRunner.app"
# The phone-remote pairing secret is a credential, not a diagnostic: remove it.
/bin/rm -f "$HOME/Library/Application Support/LidRunner/remote-secret"
CAPTURE_PLIST="$HOME/Library/LaunchAgents/com.anmolbhatia.lidrunner.captureguard.plist"
/bin/launchctl bootout "gui/$(id -u)" "$CAPTURE_PLIST" 2>/dev/null || true
/bin/rm -f "$CAPTURE_PLIST"
/bin/rm -rf "$HOME/Applications/LidRunner Capture Guard.app"
printf '%s\n' 'Normal sleep restored. LidRunner removed; source and user diagnostics retained.'
