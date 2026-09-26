"""C04 contract-v1 adapter over pinned agent-browser 0.38.1 typed MCP tools.

The owner must supply a pre-bound pinned session. This adapter never calls
connect/close, discovers an endpoint, creates a tab, or kills a daemon.
"""
from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
import hashlib
import json
import platform
import re
import threading
import time
from typing import Any, Callable
from urllib.parse import urlsplit

from contract import Request, Result, Target
from evidence import ROOT

VERSION = '0.38.1'
NATIVE_SHA256 = {
    'arm64': '2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d',
    'x86_64': '9187f885f7da0a6d880ff6d2e7dea58e17bea490a1fec85bbb6a36067272ea8e',
}
IDENTITY_JS = "JSON.stringify({run:window.CONFIG?.run,generation:window.CONFIG?.generation,target:window.CONFIG?.target,url:location.href,nonce:window.fixtureSessionNonce})"
TOOLS = {'observe': 'agent_browser_snapshot', 'click': 'agent_browser_click',
         'fill': 'agent_browser_fill', 'evaluate': 'agent_browser_eval',
         'wait': 'agent_browser_wait_ms', 'upload': 'agent_browser_upload',
         'download': 'agent_browser_download'}


def _data(response: Any) -> Any:
    if not isinstance(response, dict) or response.get('isError') is not False:
        raise ValueError('MCP error or malformed envelope')
    structured = response.get('structuredContent')
    if not isinstance(structured, dict) or structured.get('exitCode') != 0:
        raise ValueError('CLI exit status missing or nonzero')
    parsed = structured.get('response')
    if not isinstance(parsed, dict) or parsed.get('success') is not True or 'data' not in parsed:
        raise ValueError('CLI JSON result missing or failed')
    return parsed['data']


class AgentBrowserAdapter:
    candidate_id = 'C04'
    candidate_version = VERSION

    def __init__(self, rpc: Callable[[str, dict[str, Any], str, int], dict[str, Any]], *,
                 notify: Callable[[str, dict[str, Any]], None] | None = None,
                 artifact_verified: bool = False, executable_path: Path | None = None,
                 executable_sha256: str | None = None, selected_profile: str | None = None,
                 endpoint: str | None = None, namespace: str | None = None,
                 session: str | None = None, prebound_pin_attested: bool = False,
                 connection_approved: bool = False,
                 allowed_upload_roots: tuple[Path, ...] = (),
                 allowed_download_root: Path | None = None):
        self.rpc = rpc
        self.notify = notify  # deliberately unused: pinned MCP ignores notifications
        self.artifact_verified = artifact_verified
        self.executable_path = Path(executable_path) if executable_path else None
        self.executable_sha256 = executable_sha256
        self.selected_profile = selected_profile
        self.endpoint = endpoint
        self.namespace = namespace
        self.session = session
        self.prebound_pin_attested = prebound_pin_attested
        self.connection_approved = connection_approved
        self.allowed_upload_roots = tuple(Path(p).resolve() for p in allowed_upload_roots)
        self.allowed_download_root = Path(allowed_download_root).resolve() if allowed_download_root else None
        self._lock = threading.Lock()
        self._target: Target | None = None
        self._in_flight: str | None = None
        self._stopped = False
        self._uncertain = False

    def preflight(self) -> Result:
        missing = []
        if (not self.artifact_verified or not self.executable_path or not self.executable_path.is_file()
                or not self.executable_path.resolve().is_relative_to(ROOT.resolve())
                or not isinstance(self.executable_sha256, str)
                or not re.fullmatch(r'[0-9a-f]{64}', self.executable_sha256)
                or self.executable_sha256 != NATIVE_SHA256.get(platform.machine())
                or hashlib.sha256(self.executable_path.read_bytes()).hexdigest() != self.executable_sha256):
            missing.append('verified exact native executable 0.38.1 identity')
        if not self.selected_profile:
            missing.append('current selected browser profile')
        if not self.endpoint or not re.fullmatch(r'(?:http|ws)://127\.0\.0\.1:[1-9][0-9]*(?:/[^\s]*)?', self.endpoint):
            missing.append('explicit loopback CDP endpoint')
        if not self.namespace or not re.fullmatch(r'context-desk-[a-z0-9-]+', self.namespace):
            missing.append('app-owned daemon namespace')
        if not self.session or not re.fullmatch(r'context-desk-[a-z0-9-]+', self.session):
            missing.append('app-owned named session')
        if not self.prebound_pin_attested:
            missing.append('owner-attested pre-bound --pin-tab target')
        if not self.connection_approved:
            missing.append('current CDP connection approval')
        return Result('blocked' if missing else 'passed', error='; '.join(missing) or None,
                      details={'browser_tool_calls': 0, 'native_route': 'exact executable, pre-bound session',
                               'pin_attestation_source': 'owner; MCP session-info omits pin state'})

    def _rpc(self, tool: str, args: dict[str, Any], request_id: str, deadline_ns: int) -> dict[str, Any]:
        with self._lock:
            if self._stopped or deadline_ns <= time.monotonic_ns():
                raise RuntimeError('Stop or deadline before candidate RPC')
        common = {'namespace': self.namespace, 'session': self.session, 'timeoutMs': max(1, min(30000, (deadline_ns - time.monotonic_ns()) // 1_000_000))}
        return self.rpc('tools/call', {'name': tool, 'arguments': {**common, **args}}, request_id, deadline_ns)

    def _valid_target(self, target: Target) -> bool:
        if not all((target.run_id, target.generation, target.url, target.nonce, target.profile, target.target_id)) or target.profile != self.selected_profile:
            return False
        if not re.fullmatch(r'[A-Fa-f0-9]{32}', target.target_id):
            return False
        parsed = urlsplit(target.url)
        try:
            if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or not parsed.port or parsed.query or parsed.fragment or parsed.username or parsed.password:
                return False
        except ValueError:
            return False
        return parsed.path in {f'/{target.run_id}/{name}' for name in ('A', 'B', 'decoy')}

    def _guard(self, target: Target, rid: str, deadline_ns: int) -> dict[str, Any]:
        tabs = _data(self._rpc('agent_browser_tab_list', {}, rid + ':tabs', deadline_ns))
        if not isinstance(tabs, dict) or not isinstance(tabs.get('tabs'), list):
            raise ValueError('invalid tab listing')
        matching = [t for t in tabs['tabs'] if isinstance(t, dict) and t.get('targetId') == target.target_id]
        if len(matching) != 1 or matching[0].get('active') is not True or matching[0].get('url') != target.url:
            raise ValueError('pinned active CDP target absent or URL changed')
        value = _data(self._rpc('agent_browser_eval', {'script': IDENTITY_JS}, rid + ':identity', deadline_ns))
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except ValueError:
                pass
        if isinstance(value, dict) and isinstance(value.get('result'), str):
            value = json.loads(value['result'])
        expected = {'run': target.run_id, 'generation': target.generation,
                    'target': urlsplit(target.url).path.rsplit('/', 1)[-1],
                    'url': target.url, 'nonce': target.nonce}
        if value != expected:
            raise ValueError('fixture run/generation/URL/nonce mismatch')
        return expected

    def attach(self, request: Request) -> Result:
        if request.operation != 'attach' or request.deadline_ns <= time.monotonic_ns() or not self._valid_target(request.target):
            return Result('blocked', error='invalid target/attach/deadline')
        preflight = self.preflight()
        if preflight.status != 'passed':
            return preflight
        with self._lock:
            if self._target or self._stopped or self._uncertain or self._in_flight:
                return Result('blocked', error='already attached, stopped, uncertain or busy')
            self._in_flight = request.request_id
        try:
            info = _data(self._rpc('agent_browser_session_info', {}, request.request_id + ':session', request.deadline_ns))
            if (not isinstance(info, dict) or info.get('session') != self.session
                    or info.get('namespace') != self.namespace or info.get('active') is not True
                    or info.get('version') != VERSION or not isinstance(info.get('runtime'), dict)
                    or info['runtime'].get('browserLaunched') is not True):
                raise ValueError('owned active session/native version not verified')
            identity = self._guard(request.target, request.request_id, request.deadline_ns)
            with self._lock:
                if self._stopped:
                    self._uncertain = True
                    return Result('failed', error='Stop raced with identity readback', uncertain=True, dispatched=True)
                self._target = request.target
            return Result('passed', value=identity, dispatched=True,
                          details={'pin': 'owner-attested; not exposed by MCP session info',
                                   'browser_visibility': 'CDP browser-wide; action constrained to active pinned target'})
        except Exception as error:
            with self._lock:
                self._uncertain = True
            return Result('failed', error=f'{type(error).__name__}: {error}', uncertain=True, dispatched=True)
        finally:
            with self._lock:
                self._in_flight = None

    def _map(self, request: Request) -> tuple[str, dict[str, Any]] | None:
        a = request.arguments
        if not isinstance(a, dict):
            return None
        op = request.operation
        if op == 'observe' and set(a) <= {'interactive', 'compact', 'depth', 'selector'}:
            return TOOLS[op], a
        if op == 'click' and set(a) == {'selector'} and isinstance(a['selector'], str):
            return TOOLS[op], a
        if op == 'fill' and set(a) == {'selector', 'text'} and all(isinstance(a[k], str) for k in a):
            return TOOLS[op], a
        if op == 'evaluate' and set(a) == {'script'} and isinstance(a['script'], str):
            return TOOLS[op], a
        if op == 'wait' and set(a) == {'ms'} and type(a['ms']) is int and 0 <= a['ms'] <= 30000:
            return TOOLS[op], a
        if (op == 'upload' and set(a) == {'selector', 'files'} and isinstance(a['selector'], str)
                and isinstance(a['files'], list) and a['files'] and self.allowed_upload_roots
                and all(root.is_relative_to(ROOT.resolve()) for root in self.allowed_upload_roots)):
            files = []
            for raw in a['files']:
                if not isinstance(raw, str) or not Path(raw).is_absolute():
                    return None
                try:
                    path = Path(raw).resolve(strict=True)
                except OSError:
                    return None
                if not path.is_file() or not any(path.is_relative_to(root) for root in self.allowed_upload_roots):
                    return None
                files.append(str(path))
            return TOOLS[op], {'selector': a['selector'], 'files': files}
        if (op == 'download' and set(a) == {'selector', 'path'} and isinstance(a['selector'], str)
                and isinstance(a['path'], str) and self.allowed_download_root
                and self.allowed_download_root.is_relative_to(ROOT.resolve())):
            path = Path(a['path'])
            try:
                if (path.is_absolute() and path.parent.resolve(strict=True) == self.allowed_download_root
                        and not path.exists() and not path.is_symlink()):
                    return TOOLS[op], a
            except OSError:
                return None
        return None

    def execute(self, request: Request) -> Result:
        if request.operation not in TOOLS:
            return Result('not applicable', error='operation unavailable in bounded C04 mapping')
        mapped = self._map(request)
        if mapped is None or request.deadline_ns <= time.monotonic_ns():
            return Result('blocked', error='invalid native fields, file boundary or deadline')
        with self._lock:
            if self._target is None or self._target != request.target or self._stopped or self._uncertain or self._in_flight:
                return Result('blocked', error='target mismatch, Stop, uncertainty or busy')
            self._in_flight = request.request_id
        try:
            self._guard(request.target, request.request_id, request.deadline_ns)
            tool, args = mapped
            response = self._rpc(tool, args, request.request_id, request.deadline_ns)
            value = _data(response)
            with self._lock:
                if self._stopped:
                    self._uncertain = True
                    return Result('failed', error='late response after Stop; daemon cessation unknown', uncertain=True, dispatched=True)
            return Result('passed', value=value, dispatched=True, details={'tool': tool, 'guard': 'non-atomic'})
        except Exception as error:
            with self._lock:
                self._uncertain = True
            return Result('failed', error=f'{type(error).__name__}: {error}', uncertain=True, dispatched=True)
        finally:
            with self._lock:
                self._in_flight = None

    def cancel(self, request_id: str) -> Result:
        with self._lock:
            self._stopped = True
            in_flight = self._in_flight == request_id
            self._uncertain |= in_flight
        return Result('not applicable', error='pinned MCP ignores id-less cancellation notifications; host Stop gate latched',
                      uncertain=in_flight, details={'notification_sent': False, 'cancel_ack': None,
                                                    'cessation_verified': False})

    def inspect_state(self) -> dict[str, Any]:
        with self._lock:
            return {'target': asdict(self._target) if self._target else None,
                    'in_flight': self._in_flight, 'stopped': self._stopped,
                    'uncertain': self._uncertain, 'cessation_verified': False,
                    'daemon_ownership': 'runner/owner must verify independently'}

    def detach(self) -> Result:
        with self._lock:
            self._stopped = True
            if self._in_flight or self._uncertain:
                return Result('blocked', error='in-flight/uncertain work requires reconciliation', uncertain=True)
            self._target = None
        return Result('passed', details={'browser_action': 'none', 'daemon_action': 'none'})
