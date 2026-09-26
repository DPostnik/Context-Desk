"""C02 direct-driver adapter for the pinned Playwright MCP extension route.

All browser calls go through the injected RPC. The host must audit dispatch and
retain an uncertain target after Stop, timeout, loss, or failed identity readback.
"""
from __future__ import annotations

import json
import re
import threading
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

from contract import Request, Result, Target
from evidence import ROOT


IDENTITY_JS = "() => ({run: window.CONFIG?.run, generation: window.CONFIG?.generation, target: window.CONFIG?.target, url: location.href, nonce: window.fixtureSessionNonce})"
TAB_LINE = re.compile(r"^- (\d+):( \(current\))? \[[^\]]*\]\(([^\n]*)\)(?: \[crashed\])?$", re.M)
ALLOWED = {'observe', 'click', 'fill', 'evaluate', 'wait', 'upload'}
MCP_VERSION = '0.0.82'
LIBRARY_VERSION = '1.64.0-alpha-1789764292000'


def _section(value: dict[str, Any], name: str) -> str | None:
    if value.get('isError'):
        raise ValueError('MCP tool returned isError')
    blocks = value.get('content')
    if not isinstance(blocks, list) or not blocks or any(not isinstance(b, dict) for b in blocks):
        raise ValueError('invalid MCP content')
    text = '\n'.join(b['text'] for b in blocks if b.get('type') == 'text' and isinstance(b.get('text'), str))
    match = re.search(r'(?ms)^### ' + re.escape(name) + r'\n(.*?)(?=^### |\Z)', text)
    return match.group(1).strip() if match else None


def _valid_envelope(value: Any) -> bool:
    return (isinstance(value, dict) and not value.get('isError', False) and
            isinstance(value.get('content'), list) and bool(value['content']) and
            all(isinstance(block, dict) and block.get('type') == 'text' and
                isinstance(block.get('text'), str) for block in value['content']))


class PlaywrightAdapter:
    candidate_id = 'C02'
    candidate_version = MCP_VERSION

    def __init__(self, rpc: Callable[[str, dict[str, Any], str, int], dict[str, Any]], *,
                 notify: Callable[[str, dict[str, Any]], None] | None = None,
                 artifact_verified: bool = False, extension_version: str | None = None,
                 extension_artifact_sha256: str | None = None,
                 selected_profile: str | None = None, connection_approved: bool = False,
                 allowed_upload_roots: tuple[Path, ...] = ()):
        self.rpc = rpc
        self.notify = notify
        self.artifact_verified = artifact_verified
        self.extension_version = extension_version
        self.extension_artifact_sha256 = extension_artifact_sha256
        self.selected_profile = selected_profile
        self.connection_approved = connection_approved
        self.allowed_upload_roots = tuple(Path(p).resolve() for p in allowed_upload_roots)
        self._lock = threading.Lock()
        self._target: Target | None = None
        self._index: int | None = None
        self._in_flight: str | None = None
        self._active_rpc_id: str | None = None
        self._stopped = False
        self._uncertain = False

    def preflight(self) -> Result:
        missing = []
        if not self.artifact_verified:
            missing.append('pinned MCP and alpha-library artifact verification')
        if self.extension_version != '0.4.0' or not isinstance(self.extension_artifact_sha256, str) or not re.fullmatch(r'[0-9a-f]{64}', self.extension_artifact_sha256):
            missing.append('actual installed extension 0.4.0 artifact identity')
        if not isinstance(self.selected_profile, str) or not self.selected_profile.strip():
            missing.append('current explicit browser profile selection')
        if not self.connection_approved:
            missing.append('current extension connection approval')
        return Result('blocked' if missing else 'passed', error='; '.join(missing) or None,
                      details={'browser_tool_calls': 0, 'extension_group_scope': 'source-described; runtime unverified'})

    def _rpc(self, tool: str, args: dict[str, Any], request_id: str, deadline_ns: int) -> dict[str, Any]:
        with self._lock:
            if self._stopped or deadline_ns <= time.monotonic_ns():
                raise RuntimeError('Stop or deadline before candidate RPC')
            self._active_rpc_id = request_id
        try:
            return self.rpc('tools/call', {'name': tool, 'arguments': args}, request_id, deadline_ns)
        finally:
            with self._lock:
                if self._active_rpc_id == request_id:
                    self._active_rpc_id = None

    def _tabs(self, request_id: str, deadline_ns: int) -> list[tuple[int, bool, str]]:
        response = self._rpc('browser_tabs', {'action': 'list'}, request_id, deadline_ns)
        result = _section(response, 'Result')
        if result is None:
            raise ValueError('missing tab listing')
        tabs = [(int(m.group(1)), bool(m.group(2)), m.group(3)) for m in TAB_LINE.finditer(result)]
        if not tabs or len(tabs) != len(result.splitlines()):
            raise ValueError('unrecognized tab listing')
        return tabs

    def _identity(self, request_id: str, deadline_ns: int) -> dict[str, Any]:
        response = self._rpc('browser_evaluate', {'function': IDENTITY_JS}, request_id, deadline_ns)
        value = _section(response, 'Result')
        if value is None:
            raise ValueError('missing identity result')
        identity = json.loads(value)
        if not isinstance(identity, dict):
            raise ValueError('invalid identity result')
        return identity

    def _matches(self, target: Target, identity: dict[str, Any]) -> bool:
        return identity == {'run': target.run_id, 'generation': target.generation,
                            'target': urlsplit(target.url).path.rsplit('/', 1)[-1],
                            'url': target.url, 'nonce': target.nonce}

    def _validate_target(self, target: Target) -> int | None:
        if not all((target.run_id, target.generation, target.url, target.nonce,
                    target.profile, target.target_id)) or target.profile != self.selected_profile:
            return None
        if not re.fullmatch(r'index:(0|[1-9][0-9]*)', target.target_id):
            return None
        parsed = urlsplit(target.url)
        try:
            if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or not parsed.port or parsed.username or parsed.password or parsed.query or parsed.fragment:
                return None
        except ValueError:
            return None
        if parsed.path != f'/{target.run_id}/A' and parsed.path != f'/{target.run_id}/B' and parsed.path != f'/{target.run_id}/decoy':
            return None
        return int(target.target_id[6:])

    def attach(self, request: Request) -> Result:
        if request.operation != 'attach' or request.deadline_ns <= time.monotonic_ns():
            return Result('blocked', error='invalid attach request or expired deadline')
        prior = self.preflight()
        if prior.status != 'passed':
            return prior
        index = self._validate_target(request.target)
        if index is None:
            return Result('blocked', error='explicit selected profile, index target, URL, generation and pre-attachment nonce required')
        with self._lock:
            if self._target is not None or self._stopped or self._uncertain or self._in_flight:
                return Result('blocked', error='adapter already attached, stopped, uncertain or busy')
            self._in_flight = request.request_id
        dispatched = True  # The first RPC can fail after transport acceptance.
        try:
            tabs = self._tabs(request.request_id + ':list', request.deadline_ns)
            if (index, False, request.target.url) not in tabs and (index, True, request.target.url) not in tabs:
                return Result('blocked', error='selected target index and URL absent from extension group', dispatched=True)
            self._rpc('browser_tabs', {'action': 'select', 'index': index}, request.request_id + ':select', request.deadline_ns)
            identity = self._identity(request.request_id + ':identity', request.deadline_ns)
            if not self._matches(request.target, identity):
                return Result('blocked', error='fixture run/generation/URL/nonce readback mismatch', dispatched=True)
            with self._lock:
                if self._stopped:
                    self._uncertain = True
                    return Result('failed', error='Stop raced with attachment', uncertain=True, dispatched=True)
                self._target, self._index = request.target, index
            return Result('passed', value=identity, dispatched=True,
                          details={'selection': 'extension-group tab index; index is not a stable browser tab ID',
                                   'enforcement': 'host readback only; no atomic per-tab routing'})
        except Exception as error:
            with self._lock:
                if dispatched:
                    self._uncertain = True
            return Result('failed', error=f'{type(error).__name__}: {error}', uncertain=dispatched, dispatched=dispatched)
        finally:
            with self._lock:
                self._in_flight = None

    def _map(self, request: Request) -> tuple[str, dict[str, Any]] | None:
        args = request.arguments
        if not isinstance(args, dict):
            return None
        if request.operation == 'observe' and set(args) <= {'target', 'depth', 'boxes'}:
            return 'browser_snapshot', args
        if request.operation == 'click' and isinstance(args.get('target'), str) and set(args) <= {'target', 'element', 'button', 'doubleClick', 'modifiers'}:
            return 'browser_click', args
        if request.operation == 'fill' and isinstance(args.get('fields'), list) and set(args) == {'fields'}:
            return 'browser_fill_form', args
        if request.operation == 'evaluate' and isinstance(args.get('function'), str) and set(args) <= {'function', 'target', 'element'}:
            return 'browser_evaluate', args
        if request.operation == 'wait' and set(args) <= {'time', 'text', 'textGone'} and args:
            return 'browser_wait_for', args
        if request.operation == 'upload' and isinstance(args.get('paths'), list) and set(args) == {'paths'}:
            paths = args['paths']
            if not paths or not self.allowed_upload_roots:
                return None
            for raw in paths:
                if not isinstance(raw, str):
                    return None
                path = Path(raw)
                try:
                    resolved = path.resolve(strict=True)
                except OSError:
                    return None
                if not path.is_absolute() or not resolved.is_file() or not any(
                        root.is_relative_to(ROOT.resolve()) and resolved.is_relative_to(root)
                        for root in self.allowed_upload_roots):
                    return None
            return 'browser_file_upload', {'paths': [str(Path(p).resolve()) for p in paths]}
        return None

    def execute(self, request: Request) -> Result:
        if request.operation == 'download':
            return Result('not applicable', error='pinned MCP has no direct download tool; use fixture HTTP readback outside this adapter')
        if request.operation not in ALLOWED or (mapped := self._map(request)) is None:
            return Result('blocked', error='operation or candidate-native fields not allowlisted')
        if request.deadline_ns <= time.monotonic_ns():
            return Result('blocked', error='expired deadline')
        with self._lock:
            if self._target != request.target or self._target is None or self._stopped or self._uncertain or self._in_flight:
                return Result('blocked', error='target mismatch, Stop, uncertainty or busy')
            self._in_flight = request.request_id
        dispatched = True  # Identity/list RPC may have been accepted before a transport exception.
        try:
            tabs = self._tabs(request.request_id + ':list', request.deadline_ns)
            if (self._index, True, request.target.url) not in tabs:
                return Result('blocked', error='selected tab index/current URL changed', dispatched=True)
            identity = self._identity(request.request_id + ':identity', request.deadline_ns)
            if not self._matches(request.target, identity):
                return Result('blocked', error='target identity changed', dispatched=True)
            tool, args = mapped
            response = self._rpc(tool, args, request.request_id, request.deadline_ns)
            if not _valid_envelope(response):
                raise ValueError('MCP tool returned malformed or error envelope')
            with self._lock:
                if self._stopped:
                    self._uncertain = True
                    return Result('failed', error='late response after Stop; cessation unknown', uncertain=True, dispatched=True)
            return Result('passed', value=response, dispatched=True,
                          details={'tool': tool, 'identity_check': 'before action, non-atomic'})
        except Exception as error:
            with self._lock:
                if dispatched:
                    self._uncertain = True
            return Result('failed', error=f'{type(error).__name__}: {error}', uncertain=dispatched, dispatched=dispatched)
        finally:
            with self._lock:
                self._in_flight = None

    def cancel(self, request_id: str) -> Result:
        with self._lock:
            self._stopped = True
            in_flight = self._in_flight == request_id
            active_rpc_id = self._active_rpc_id
            self._uncertain |= in_flight
        if not in_flight:
            return Result('not applicable', error='no matching in-flight call; Stop gate remains latched')
        if self.notify is None:
            return Result('not applicable', error='no cancellation notification transport; cessation unknown', uncertain=True)
        try:
            if active_rpc_id is None:
                return Result('blocked', error='Stop latched between RPC calls; no active candidate request to cancel',
                              uncertain=True)
            self.notify('notifications/cancelled', {'requestId': active_rpc_id, 'reason': 'host Stop'})
            return Result('blocked', error='cancellation notification sent; no ACK or cessation proof',
                          uncertain=True, dispatched=True,
                          details={'notification_sent': True, 'cancel_ack': None, 'cessation_verified': False})
        except Exception as error:
            return Result('failed', error=f'cancellation transport: {type(error).__name__}: {error}', uncertain=True, dispatched=True)

    def inspect_state(self) -> dict[str, Any]:
        with self._lock:
            return {'target': asdict(self._target) if self._target else None, 'tab_index': self._index,
                    'in_flight': self._in_flight, 'active_rpc_id': self._active_rpc_id,
                    'stopped': self._stopped, 'uncertain': self._uncertain,
                    'browser_wide_visibility': 'extension group is source-described; runtime unverified',
                    'cessation_verified': False}

    def detach(self) -> Result:
        with self._lock:
            self._stopped = True
            if self._in_flight or self._uncertain:
                return Result('blocked', error='in-flight or uncertain work requires independent reconciliation',
                              uncertain=True, details={'browser_action': 'none', 'cessation_verified': False})
            self._target = None
            self._index = None
            return Result('passed', details={'browser_action': 'none', 'transport_cleanup': 'runner owns injected transport',
                                             'uncertain': self._uncertain})
