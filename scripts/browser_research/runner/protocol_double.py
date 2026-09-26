#!/usr/bin/env python3
"""Deliberately tiny stdio peer used only by runner self-checks."""
import json
import sys
import time


def send(value):
    sys.stdout.write(json.dumps(value) + '\n')
    sys.stdout.flush()


def main(mode):
    if mode == 'noread':
        time.sleep(2)
        return
    for line in sys.stdin:
        message = json.loads(line)
        if 'method' not in message:
            continue
        if mode == 'server-request':
            send({'jsonrpc': '2.0', 'id': 'server-1', 'method': 'roots/list', 'params': {}})
            denial = json.loads(sys.stdin.readline())
            if denial.get('error', {}).get('code') != -32601:
                raise SystemExit(2)
            return
        if mode == 'server-notification':
            send({'jsonrpc': '2.0', 'method': 'unexpected/notice', 'params': {}})
            return
        if mode == 'eof':
            return
        if mode == 'mcp-handshake':
            if message['method'] == 'initialize':
                send({'jsonrpc': '2.0', 'id': message['id'], 'result': {
                    'protocolVersion': '2025-11-25', 'serverInfo': {'version': '0.double'}}})
            elif message['method'] == 'tools/list':
                send({'jsonrpc': '2.0', 'id': message['id'], 'result': {
                    'tools': [{'name': 'double_tool'}]}})
            continue
        if mode == 'late':
            time.sleep(0.2)
        if 'id' in message:
            send({'jsonrpc': '2.0', 'id': message['id'],
                  'result': {'method': message['method'], 'params': message.get('params', {})}})


if __name__ == '__main__':
    main(sys.argv[1])
