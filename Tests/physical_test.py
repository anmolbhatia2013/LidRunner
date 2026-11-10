"""Observe an explicitly requested physical lid-close test; never alter power settings."""
import json, pathlib, time, urllib.request, datetime
root = pathlib.Path(__file__).resolve().parents[1]
source = pathlib.Path.home() / 'Library/Application Support/LidRunner/diagnostics.json'
out = root / 'evidence' / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-closed-lid.jsonl')
start = time.monotonic()
previous = start
closed_seen = False
opened_at = None
print('Evidence: ' + str(out), flush=True)
with out.open('w') as log:
    while time.monotonic() - start < 240:
        now = time.monotonic()
        try:
            d = json.loads(source.read_text())
        except (OSError, ValueError):
            time.sleep(1)
            continue
        row = {'time': time.time(), 'observerGap': now - previous, 'diagnosticAge': time.time() - d['time'], 'app': d}
        previous = now
        closed = d['lidClosed'] and row['diagnosticAge'] < 5
        if closed and not closed_seen:
            closed_seen = True
            print('LID_CLOSED ' + json.dumps(row), flush=True)
            before = time.time()
            try:
                with urllib.request.urlopen('https://www.apple.com/library/test/success.html', timeout=10) as response:
                    row['network'] = {'httpStatus': response.status, 'successBody': b'Success' in response.read(4096), 'started': before, 'finished': time.time()}
            except Exception as e:
                row['network'] = {'error': str(e), 'started': before, 'finished': time.time()}
            print('NETWORK ' + json.dumps(row.get('network')), flush=True)
        if closed_seen and not d['lidClosed'] and opened_at is None:
            opened_at = now
            print('LID_REOPENED ' + json.dumps(row), flush=True)
        log.write(json.dumps(row) + '\n'); log.flush()
        if opened_at is not None and now - opened_at > 5:
            break
        time.sleep(1)
print('Observation complete; closed_seen=' + str(closed_seen), flush=True)
