#!/usr/bin/env python3
"""Check the stage-1 contract boundary; extend to app/UI after adapter extraction."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
failures = []
for path in sorted((root / 'Sources/AgentContract').glob('*.swift')):
    source = path.read_text()
    for imported in re.findall(r'^\s*(?:@\w+\s+)?import\s+(\w+)', source, re.MULTILINE):
        if imported != 'Foundation':
            failures.append(f'{path.name}: forbidden dependency {imported}')
    if re.search(r'\b(?:JSONValue|CodexConnection|ClaudeJobRunner)\b', source):
        failures.append(f'{path.name}: native transport/payload leaked into contract')
    if re.search(r'"(?:thread|turn|account|item|model|mcpServer)/[^"\n]+"', source):
        failures.append(f'{path.name}: native RPC method leaked into contract')
package = (root / 'Package.swift').read_text()
if '.target(name: "AgentContract"),' not in package:
    failures.append('AgentContract must remain a target with no package dependencies')
if failures:
    sys.exit('\n'.join(failures))
print('AgentContract dependency boundary passed (stage 1).')
