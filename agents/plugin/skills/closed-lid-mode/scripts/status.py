#!/usr/bin/env python3
"""Read-only Mac/LidRunner readiness. No UI, power changes, network or task data."""
import json
import math
import os
import platform
import plistlib
import subprocess
import time
from pathlib import Path

DATA_DIR = Path.home() / 'Library/Application Support/LidRunner'
ROOT_STATUS = Path('/Library/Application Support/LidRunner/status.json')
# Agent host apps LidRunner reports on. Only these keys and boolean values are copied.
AGENT_APPS = ('chatgpt', 'claude', 'gemini', 'antigravity')


def read_json(path):
    try:
        if path.stat().st_size > 65536:
            return {}
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def fresh(obj, key, now, age=8):
    stamp = obj.get(key)
    return number(stamp) and -2 <= now - stamp < age


def hardware():
    if platform.system() != 'Darwin':
        return {}
    try:
        result = subprocess.run(['/usr/sbin/ioreg', '-r', '-d', '1', '-c', 'IOPMrootDomain', '-a'],
                                capture_output=True, timeout=1.5, check=True)
        entries = plistlib.loads(result.stdout)
        root = next(x for x in entries if 'AppleClamshellState' in x)
        return {k: root.get(k) for k in ('AppleClamshellState', 'SleepDisabled')}
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, StopIteration, plistlib.InvalidFileException):
        return {}


def evaluate(hw, diag, guard, root, now, supported=True):
    # Hardware is authoritative. Fresh diagnostics are a fallback, never stale files.
    diag_fresh = fresh(diag, 'time', now)
    lid = hw.get('AppleClamshellState')
    source = 'ioreg'
    if not isinstance(lid, bool):
        lid = diag.get('lidClosed') if diag_fresh else None
        source = 'fresh_lidrunner_diagnostics' if isinstance(lid, bool) else 'unavailable'
    override = hw.get('SleepDisabled')
    if not isinstance(override, bool):
        override = diag.get('sleepDisabled') if diag_fresh else None
    if not isinstance(override, bool):
        override = None
    root_fresh = fresh(root, 'updated', now)
    deadline = root.get('deadline')
    session_active = (diag_fresh and diag.get('phase') == 'active' and root_fresh and
                      root.get('phase') == 'active' and number(deadline) and deadline > now)
    guard_fresh = fresh(guard, 'time', now)
    guard_ready = (guard_fresh and guard.get('accessibilityTrusted') is True and
                   guard.get('sessionEligible') is True and lid is True and session_active and override is True)
    battery = diag.get('batteryPercent') if diag_fresh else None
    if not number(battery) or not 0 <= battery <= 100:
        battery = None
    on_charger = diag.get('onCharger') if diag_fresh else None
    if not isinstance(on_charger, bool):
        on_charger = None
    apps = diag.get('agentApps') if diag_fresh else None
    agent_apps = {k: apps[k] for k in AGENT_APPS if isinstance(apps, dict) and isinstance(apps.get(k), bool)}
    if 'chatgpt' not in agent_apps and diag_fresh and isinstance(diag.get('chatGPTRunning'), bool):
        agent_apps['chatgpt'] = diag['chatGPTRunning']  # LidRunner 1.1 diagnostics
    mode = 'unsupported_host' if not supported else ('closed' if lid is True else 'open' if lid is False else 'unknown')
    alerts = []
    if mode == 'closed' and not (session_active and override is True):
        alerts.append('closed_lid_power_session_not_verified')
    if mode == 'closed' and not guard_ready:
        alerts.append('automatic_capture_recovery_not_ready')
    if on_charger is False and battery is not None and battery <= 20:
        alerts.append('battery_near_15_percent_cutoff')
    if session_active and deadline - now <= 300:
        alerts.append('session_expires_within_5_minutes')
    if mode == 'unknown':
        alerts.append('lid_state_unavailable')
    return {
        'mode': mode, 'lid_source': source, 'power_session_active': bool(session_active),
        'sleep_override': override, 'capture_guard_ready': bool(guard_ready),
        'guard_permission': guard.get('accessibilityTrusted') if guard_fresh and isinstance(guard.get('accessibilityTrusted'), bool) else None,
        'battery_percent': battery, 'on_charger': on_charger,
        'session_remaining_seconds': max(0, int(deadline-now)) if session_active else None,
        'agent_apps_running': agent_apps or None,
        'diagnostics_fresh': bool(diag_fresh), 'guard_fresh': bool(guard_fresh),
        'alerts': alerts,
        'desktop_actions': 'verify_current_app_capture_and_input; status is not capability proof',
    }


def simulated(kind, now):
    """Test-only host state for end-to-end agent checks. Always labelled in the output."""
    closed = kind == 'closed'
    diag = {'time': now, 'phase': 'active', 'lidClosed': closed, 'sleepDisabled': True, 'batteryPercent': 40, 'onCharger': False}
    result = evaluate({'AppleClamshellState': closed, 'SleepDisabled': True}, diag,
                      {'time': now, 'accessibilityTrusted': True, 'sessionEligible': True},
                      {'updated': now, 'phase': 'active', 'deadline': now + 3600}, now)
    result['simulated'] = True
    result['lid_source'] = 'simulated'
    return result


def collect():
    # LIDRUNNER_SIMULATE_LID=closed|open fakes the state for agent tests; output says so.
    kind = os.environ.get('LIDRUNNER_SIMULATE_LID')
    if kind in ('closed', 'open'):
        return simulated(kind, time.time())
    supported = platform.system() == 'Darwin'
    if not supported:
        return evaluate({}, {}, {}, {}, time.time(), supported=False)
    return evaluate(hardware(), read_json(DATA_DIR/'diagnostics.json'),
                    read_json(DATA_DIR/'capture-guard.json'), read_json(ROOT_STATUS), time.time())


if __name__ == '__main__':
    print(json.dumps(collect(), separators=(',', ':')))
