#!/usr/bin/env python3
"""Check the independent contract and the extracted Codex command boundary."""
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
# Stage 3a isolates commands and transport. Legacy event/approval JSON is still
# permitted until its separately tested normalization is implemented.
for folder in ['ContextCore', 'ContextDesk', 'ContextTranscript']:
    for path in sorted((root / 'Sources' / folder).glob('*.swift')):
        source = path.read_text()
        if re.search(r'\bCodexConnection\b|@_spi\s*\(\s*NativeProtocol', source):
            failures.append(f'{path}: native transport bypasses CodexClient')
        if folder in ['ContextDesk', 'ContextTranscript'] and re.search(r'\.request\s*\(', source):
            failures.append(f'{path}: raw RPC dispatch in application/UI')
        if folder != 'ContextDesk' and re.search(r'import\s+CodexAdapter', source):
            failures.append(f'{path}: adapter dependency in shared core/transcript')
if '.target(name: "CodexAdapter", dependencies: ["AgentContract", "ContextCore"]),' not in package:
    failures.append('CodexAdapter must depend only on AgentContract and ContextCore')
if (root / 'Sources/ContextCore/CodexConnection.swift').exists():
    failures.append('Native transport must live in CodexAdapter')
if failures:
    sys.exit('\n'.join(failures))
print('AgentContract and Codex command boundaries passed (stage 3a; legacy event bridge remains).')
