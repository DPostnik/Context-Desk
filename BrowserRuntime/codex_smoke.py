#!/usr/bin/env python3
"""Verify MCP discovery through Codex using a fresh, unauthenticated scratch home."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('codex', type=Path)
    parser.add_argument('--resources', type=Path, default=Path(__file__).parent)
    parser.add_argument('--disabled', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='context-desk-codex-browser-check-') as temporary:
        root = Path(temporary)
        home = root / 'codex'
        home.mkdir()
        prefix = 'mcp_servers.context_desk_browser'
        settings = [prefix + '.command="/usr/bin/python3"', prefix + '.args=' + json.dumps([
            str(args.resources.resolve() / 'server.py'), '--root', str(root / 'browser'), '--language', 'en']),
            prefix + '.enabled=true', prefix + '.startup_timeout_sec=30', 'analytics.enabled=false']
        if args.disabled:
            settings = ['analytics.enabled=false']
        command = [str(args.codex), 'app-server', '--listen', 'stdio://']
        for setting in settings:
            command += ['-c', setting]
        env = {k: v for k, v in os.environ.items() if k not in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL', 'OPENAI_API_BASE', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE')}
        env['CODEX_HOME'] = str(home)
        child = subprocess.Popen(command, env=env, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        buffer = b''

        def send(value):
            child.stdin.write(json.dumps(value).encode() + b'\n')
            child.stdin.flush()

        def receive(request_id):
            nonlocal buffer
            end = time.monotonic() + 35
            while time.monotonic() < end:
                if b'\n' not in buffer:
                    if not selector.select(0.2):
                        continue
                    chunk = os.read(child.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError('Codex exited before response')
                    buffer += chunk
                    if len(buffer) > 4_000_000:
                        raise RuntimeError('Oversized response')
                    continue
                raw, buffer = buffer.split(b'\n', 1)
                value = json.loads(raw)
                if 'method' in value and 'id' in value:
                    send({'id': value['id'], 'error': {'code': -32601, 'message': 'No requests authorized by smoke test'}})
                    raise RuntimeError('Unexpected server request')
                if value.get('id') == request_id:
                    if 'error' in value:
                        raise RuntimeError(str(value['error']))
                    return value['result']
            raise TimeoutError('No replay after response timeout')

        try:
            send({'id': 'init', 'method': 'initialize', 'params': {'clientInfo': {'name': 'context_desk_browser_check', 'version': '1'}, 'capabilities': {'experimentalApi': True}}})
            receive('init')
            send({'method': 'initialized', 'params': {}})
            send({'id': 'mcp', 'method': 'mcpServerStatus/list', 'params': {}})
            result = receive('mcp')
            entries = result.get('data', [])
            if args.disabled:
                assert not any(x['name'] == 'context_desk_browser' for x in entries)
                print(json.dumps({'result': 'passed', 'disabled': True, 'modelCalls': 0}))
                return
            server = next(x for x in entries if x['name'] == 'context_desk_browser')
            tools = server.get('tools', {})
            assert len(tools) == 8, {'toolCount': len(tools), 'runtimeStatus': server.get('runtimeStatus'), 'toolsError': server.get('toolsError')}
            assert not (root / 'browser/profile').exists(), 'Discovery must not launch Chrome'
            print(json.dumps({'result': 'passed', 'discoveredTools': len(tools), 'scratchHome': True,
                              'browserLaunched': False, 'modelCalls': 0}))
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=5)
            selector.close()


if __name__ == '__main__':
    main()
