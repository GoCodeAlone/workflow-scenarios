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
d['lastUpdated'] = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00', 'Z')
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
        python3 -c "
import json, datetime
with open('scenarios.json', 'r') as f:
    d = json.load(f)
s = d['scenarios']['$SCENARIO']
now = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00', 'Z')
s['lastTested'] = now
s['lastResult'] = '$RESULT'
s['testCount'] = $TOTAL
s['passCount'] = $PASS
s['failCount'] = $FAIL
s['status'] = 'passed' if '$RESULT' == 'pass' else 'failed'
d['lastUpdated'] = now
with open('scenarios.json', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
        ;;
esac
