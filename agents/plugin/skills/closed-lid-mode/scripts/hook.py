#!/usr/bin/env python3
"""Advisory lifecycle hook for Codex, Claude Code and Antigravity (Gemini).

Observes host state and emits only relevant state changes. It never approves,
denies or rewrites a tool call, and never stores prompts, tool data or paths.

    hook.py                      Codex (default; keeps the existing hooks.json command)
    hook.py --host claude        Claude Code
    hook.py --host antigravity --event PreInvocation
"""
import fcntl
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from status import collect, read_json

SKILL = Path(__file__).resolve().parents[1] / 'SKILL.md'
CACHE_ROOT = Path.home() / 'Library/Caches/LidRunner'
HOSTS = ('codex', 'claude', 'antigravity')
MAX_INPUT = 8 * 1024 * 1024
# Every agent session leaves a small state file, and headless agents can start hundreds of
# sessions a day. Forget sessions idle for a day (a forgotten session just behaves like a new
# one), checking at most hourly so the common path stays one stat() call.
PRUNE_AFTER = 24 * 3600
PRUNE_EVERY = 3600

# Claude Code and Codex share an event schema. Antigravity names its own events and
# sends no event name in the payload, so its hooks.json passes --event.
KINDS = {
    'codex': {'SessionStart': 'session', 'UserPromptSubmit': 'turn', 'PreToolUse': 'tool', 'PostToolUse': 'tool'},
    'claude': {'SessionStart': 'session', 'UserPromptSubmit': 'turn', 'PreToolUse': 'tool', 'PostToolUse': 'tool'},
    'antigravity': {'PreInvocation': 'invocation'},
}
NAMES = {'codex': 'Codex', 'claude': 'Claude', 'antigravity': 'Antigravity'}


def fingerprint(state):
    # Don't inject on every 1% battery drop or countdown tick.
    keys = ('mode', 'power_session_active', 'sleep_override', 'capture_guard_ready', 'guard_permission', 'alerts')
    return {key: state.get(key) for key in keys}


def context(state, host='codex'):
    mode = state['mode']
    if mode == 'open':
        return 'LidRunner host observation: lid OPEN. Normal workflow applies; discard any stale closed-lid coordinate assumptions.'
    if mode == 'unknown':
        return ('LidRunner host observation: lid state UNKNOWN. Do not treat a stale file as an open or closed lid. '
                'Continue available work; use fresh app observations if desktop control is needed.')
    return ('LidRunner host observation: lid CLOSED. Read ' + str(SKILL) + ' (closed-lid-mode skill) if not already loaded. '
            'Continue the user\'s current task with its existing authorization. '
            'Use available connectors/CLI/browser tools, and ' + NAMES.get(host, 'this agent') + '\'s computer-use tools for native UI. '
            'Refresh app state/screenshots after capture recovery; do not reuse coordinates across window moves. '
            'Do not toggle the global LidRunner shortcut, restart the agent app, or change authentication merely because the lid closed. '
            'Local status (not proof of phone connectivity or GUI capability): ' +
            json.dumps({k: state.get(k) for k in ('power_session_active', 'capture_guard_ready', 'battery_percent', 'on_charger', 'alerts')},
                       separators=(',', ':')))


def normalize(event, host, event_name=None):
    """Return (kind, name, session, turn_marker) or None for unsupported input."""
    if host == 'antigravity':
        name = event_name
        session = event.get('conversationId')
        marker = event.get('initialNumSteps')  # changes once per user turn; an integer, not content
        marker = marker if isinstance(marker, int) and not isinstance(marker, bool) else None
    else:
        name = event.get('hook_event_name')
        session = event.get('session_id')
        marker = None
    kind = KINDS.get(host, {}).get(name)
    if kind is None or not isinstance(session, str) or not session:
        return None
    return kind, name, session, marker


def render(host, name, text):
    if host == 'antigravity':
        # Ephemeral messages are dropped after the turn, so stale state never persists.
        return {'injectSteps': [{'ephemeralMessage': text}]}
    return {'hookSpecificOutput': {'hookEventName': name, 'additionalContext': text}}


def run(event, state, cache=None, host='codex', event_name=None):
    if host not in HOSTS or state['mode'] == 'unsupported_host':
        return None
    parsed = normalize(event, host, event_name)
    if parsed is None:
        return None
    kind, name, session, marker = parsed
    cache = cache or CACHE_ROOT / (host + '-hooks')
    # IDs are hashed before use in paths. Never retain input, transcript, cwd, or prompt.
    key = hashlib.sha256(session.encode()).hexdigest()
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    prune(cache)
    path = cache / (key + '.json')
    lock_path = cache / (key + '.lock')
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = read_json(path)
        mark = fingerprint(state)
        changed = previous.get('state') != mark
        if kind == 'invocation':
            # Antigravity: the first model call of a new user turn behaves like a turn start.
            kind = 'turn' if marker is None or previous.get('turn') != marker else 'tool'
        # Force compact/resume restoration. At new turns remind only for closed/unknown.
        force = kind == 'session' or (kind == 'turn' and state['mode'] in ('closed', 'unknown'))
        data = {'time': time.time(), 'state': mark}
        if marker is not None:
            data['turn'] = marker
        fd, temp = tempfile.mkstemp(prefix=key + '.', dir=cache)
        try:
            with os.fdopen(fd, 'w') as f:
                json.dump(data, f)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        if not changed and not force:
            return None
        # Ordinary open-lid startup needs no extra prompt. A reopening transition does.
        if state['mode'] == 'open' and not previous.get('state'):
            return None
        text = context(state, host)
        if state.get('simulated'):
            text = '[SIMULATED TEST STATE, not the real lid] ' + text
        return render(host, name, text)


def prune(cache, now=None):
    """Remove state for sessions idle longer than PRUNE_AFTER. Only touches our own files."""
    now = time.time() if now is None else now
    marker = cache / '.pruned'
    try:
        if now - marker.stat().st_mtime < PRUNE_EVERY:
            return 0
    except OSError:
        pass
    removed = 0
    try:
        marker.touch()
        os.utime(marker, (now, now))
        entries = list(os.scandir(cache))
    except OSError:
        return 0
    fresh = set()
    for entry in entries:  # a session is as fresh as its state file
        name = entry.name
        if name.endswith('.json') and len(name) == 69:
            try:
                if now - entry.stat(follow_symlinks=False).st_mtime < PRUNE_AFTER:
                    fresh.add(name[:64])
            except OSError:
                fresh.add(name[:64])
    for entry in entries:
        name, stem = entry.name, entry.name[:64]
        ours = len(stem) == 64 and all(c in '0123456789abcdef' for c in stem) and name[64:] in ('.json', '.lock')
        if not ours or stem in fresh or not entry.is_file(follow_symlinks=False):
            continue
        try:
            if name.endswith('.lock') and now - entry.stat(follow_symlinks=False).st_mtime < PRUNE_AFTER:
                continue  # a session that is just starting
            os.unlink(entry.path)
            removed += 1
        except OSError:
            pass
    return removed


def parse_args(argv):
    host, event_name = 'codex', None
    args = list(argv)
    while args:
        flag = args.pop(0)
        if flag == '--host' and args:
            host = args.pop(0)
        elif flag == '--event' and args:
            event_name = args.pop(0)
    return host, event_name


def main(argv=None):
    host, event_name = parse_args(sys.argv[1:] if argv is None else argv)
    result = None
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) <= MAX_INPUT:
            event = json.loads(raw)
            if isinstance(event, dict):
                result = run(event, collect(), host=host, event_name=event_name)
    except Exception:
        # Observation is advisory: never approve, deny, rewrite or stall a tool call.
        result = None
    if result:
        print(json.dumps(result, separators=(',', ':')))
    elif host == 'antigravity':
        print('{}')  # Antigravity expects a JSON object on stdout.


if __name__ == '__main__':
    main()
