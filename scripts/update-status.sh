#!/usr/bin/env bash
set -euo pipefail

SCENARIO="$1"
FIELD="$2"
VALUE="$3"

case "$FIELD" in
    deployed)
        python3 -c "
import json, datetime
with open('scenarios.json', 'r') as f:
    d = json.load(f)
d['scenarios']['$SCENARIO']['deployed'] = '$VALUE' == 'true'
_utc = getattr(datetime, 'UTC', datetime.timezone.utc)
d['lastUpdated'] = datetime.datetime.now(_utc).isoformat().replace('+00:00', 'Z')
with open('scenarios.json', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
        ;;
    test)
        RESULT="$VALUE"
        TOTAL="${4:-0}"
        PASS="${5:-0}"
        FAIL="${6:-0}"
        SKIP="${7:-0}"
        python3 - "$SCENARIO" "$RESULT" "$TOTAL" "$PASS" "$FAIL" "$SKIP" <<'PY'
import datetime, json, os, stat, sys, tempfile

scenario, result, total, passed, failed, skipped = sys.argv[1:]
status = {'pass': 'passed', 'fail': 'failed', 'skip': 'skipped'}[result]
with open('scenarios.json', 'r') as f:
    d = json.load(f)
s = d['scenarios'][scenario]
_utc = getattr(datetime, 'UTC', datetime.timezone.utc)
now = datetime.datetime.now(_utc).isoformat().replace('+00:00', 'Z')
s['lastTested'] = now
s['lastResult'] = result
s['testCount'] = int(total)
s['passCount'] = int(passed)
s['failCount'] = int(failed)
s['skipCount'] = int(skipped)
s['status'] = status
d['lastUpdated'] = now

# Same-directory replacement leaves the previous JSON intact on write failure.
mode = stat.S_IMODE(os.stat('scenarios.json').st_mode)
pending = None
try:
    with tempfile.NamedTemporaryFile(mode='w', dir='.', prefix='.scenarios.', suffix='.json', delete=False) as f:
        pending = f.name
        json.dump(d, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.chmod(pending, mode)
    os.replace(pending, 'scenarios.json')
finally:
    if pending is not None and os.path.exists(pending):
        os.unlink(pending)
PY
        ;;
esac
