#!/usr/bin/env bash
set -euo pipefail

if [ -n "${1:-}" ]; then
    # Show specific scenario status
    python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
s = d['scenarios'].get('$1', {})
print(f'Scenario: $1')
print(f'  Status:     {s.get(\"status\", \"unknown\")}')
print(f'  Namespace:  {s.get(\"namespace\", \"\")}')
print(f'  Deployed:   {s.get(\"deployed\", False)}')
print(f'  Last Test:  {s.get(\"lastTested\", \"never\")}')
print(f'  Result:     {s.get(\"lastResult\", \"n/a\")}')
print(f'  Tests:      {s.get(\"passCount\", 0)}/{s.get(\"testCount\", 0)} passed')
blockers = s.get('blockers', [])
if blockers:
    print(f'  Blockers:   {\"  \".join(blockers)}')
"
else
    # Show all scenarios
    echo "Workflow Scenario Status"
    echo "========================"
    python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
print(f'Component Versions:')
for k, v in d.get('componentVersions', {}).items():
    print(f'  {k}: {v or \"unknown\"}')
print(f'Last Updated: {d.get(\"lastUpdated\", \"never\")}')
print()
print(f'{\"Scenario\":<25} {\"Status\":<12} {\"Deployed\":<10} {\"Last Result\":<12} {\"Tests\"}')
print('-' * 75)
for name, s in d.get('scenarios', {}).items():
    status = s.get('status', 'unknown')
    deployed = 'yes' if s.get('deployed') else 'no'
    result = s.get('lastResult', '-')
    tests = f'{s.get(\"passCount\", 0)}/{s.get(\"testCount\", 0)}'
    print(f'{name:<25} {status:<12} {deployed:<10} {result:<12} {tests}')
"
fi
