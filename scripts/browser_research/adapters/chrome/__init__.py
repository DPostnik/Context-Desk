"""C01 Chrome DevTools MCP 1.10.1 direct-driver adapter.

The caller owns the MCP transport, its process, admission gate, and audit. This
module never starts Chrome or discovers a browser profile on its own.
"""

import base64
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import re
import tarfile
import threading
import time
from typing import Any, Callable

from c01_preflight import INTEGRITY, VERSION
from contract import Request, Result, Target
from evidence import ROOT


_JSON_BLOCK = re.compile(r"```json\s*\n([^`]+)\n```", re.MULTILINE)
_IDENTITY_FUNCTION = """() => {
  const c = window.CONFIG;
  return {run_id: c?.run, generation: c?.generation, target: c?.target,
    url: location.href, nonce: window.fixtureSessionNonce,
    stored_nonce: c ? sessionStorage.getItem(`research-${c.run}-${c.target}`) : null};
}"""
_TOOLS = {
    'observe': 'take_snapshot', 'click': 'click', 'fill': 'fill',
    'evaluate': 'evaluate_script', 'wait': 'wait_for', 'upload': 'upload_file',
}
_MUTATIONS = {'click', 'fill', 'evaluate', 'upload'}


class ChromeAdapter:
    """Injected, single-target C01 adapter. No method retries a dispatched call.

    ``runtime_binding_verified`` is the runner's assertion that its transport is
    the pinned process with page-ID routing and telemetry controls. This adapter
    cannot prove the assertion through the injected callable. ``browser_consent``
    means current Chrome debugging/connection consent, not a historical grant.
    """

    candidate_id = 'C01'
    candidate_version = VERSION

    def __init__(self, rpc: Callable, notify: Callable | None = None, *,
                 browser_consent: bool = False, current_profile: str | None = None,
                 runtime_binding_verified: bool = False,
                 artifact_root: Path | None = None,
                 allowed_upload_roots: tuple[Path, ...] = (),
                 close_owned_transport: Callable | None = None):
        self._rpc = rpc
        self._notify = notify
        self._consent = browser_consent
        self._profile = current_profile
        self._binding_verified = runtime_binding_verified
        self._artifact_root = artifact_root or ROOT / f'c01-{VERSION}'
        self._upload_roots = tuple(Path(p).resolve() for p in allowed_upload_roots)
        self._close_owned_transport = close_owned_transport
        self._target: Target | None = None
        self._uncertain = False
        self._active_request_id: str | None = None
        self._active_rpc_id: str | None = None
        self._active_phase: str | None = None
        self._stop_requested = False
        self._lock = threading.RLock()
        self._artifact: dict[str, Any] | None = None

    def preflight(self) -> Result:
        """Read-only check of the already acquired artifact; no browser RPC."""
        archive = self._artifact_root / f'chrome-devtools-mcp-{VERSION}.tgz'
        try:
            data = archive.read_bytes()
            if base64.b64encode(hashlib.sha512(data).digest()).decode() != INTEGRITY:
                raise ValueError('pinned archive SHA-512 mismatch')
            with tarfile.open(archive) as tar:
                members = [m for m in tar.getmembers() if m.isfile()]
                if len(members) != 359:
                    raise ValueError('unexpected distributed file count')
                names = set()
                for member in members:
                    relative = Path(member.name)
                    if relative.is_absolute() or '..' in relative.parts or relative in names:
                        raise ValueError('unsafe or duplicate archive path')
                    names.add(relative)
                    path = self._artifact_root / relative
                    if path.is_symlink() or not path.resolve().is_relative_to(self._artifact_root.resolve()):
                        raise ValueError('unsafe extracted path')
                    expected = hashlib.sha256(tar.extractfile(member).read()).digest()
                    if hashlib.sha256(path.read_bytes()).digest() != expected:
                        raise ValueError('extracted artifact mismatch')
            actual = {p.relative_to(self._artifact_root) for p in (self._artifact_root / 'package').rglob('*') if p.is_file()}
            if actual != names:
                raise ValueError('unaccounted extracted file')
            manifest = json.loads((self._artifact_root / 'package/package.json').read_text())
            if manifest.get('version') != VERSION or manifest.get('dependencies'):
                raise ValueError('unexpected package manifest')
            self._artifact = {'archive_sha512': INTEGRITY, 'files': len(names),
                              'path': str(self._artifact_root)}
            return Result('passed', value=self._artifact, details={
                'scope': 'read-only artifact verification',
                'runtime_binding': 'caller assertion; not established by artifact verification'})
        except (OSError, ValueError, tarfile.TarError, json.JSONDecodeError) as error:
            self._artifact = None
            return Result('blocked', error=f'artifact verification: {error}')

    def attach(self, request: Request) -> Result:
        with self._lock:
            if self._target is not None:
                return Result('blocked', error='already attached; explicit detach required')
            if self._active_request_id or self._stop_requested:
                return Result('blocked', error='request active or Stop latched')
            if self._uncertain:
                return Result('blocked', error='target remains uncertain; runner reconciliation required', uncertain=True)
            reason = self._prerequisite_error(request)
            if reason:
                return Result('blocked', error=reason)
            if request.operation != 'attach' or request.arguments:
                return Result('failed', error='attach accepts no operation arguments')
            self._active_request_id = request.request_id
            self._active_rpc_id = request.request_id + ':attach'
            self._active_phase = 'identity guard'
        try:
            observed = self._read_identity(request, 'attach')
            if isinstance(observed, Result):
                return observed
            with self._lock:
                if self._stop_requested:
                    return Result('blocked', error='Stop received during attachment identity read', dispatched=True)
            if not self._identity_matches(observed, request.target):
                return Result('blocked', error='fixture run/generation/URL/nonce/target mismatch',
                              dispatched=True, details={'observed_identity': observed})
            with self._lock:
                if self._stop_requested:
                    return Result('blocked', error='Stop received during attachment identity read', dispatched=True)
                self._target = request.target
            return Result('passed', value=observed, dispatched=True,
                          details={'identity_check': 'page-scoped evaluate_script',
                                   'browser_wide_visibility': 'MCP connection can see other Chrome pages; host selection is not a browser isolation grant'})
        finally:
            with self._lock:
                if self._active_request_id == request.request_id:
                    self._active_request_id = self._active_rpc_id = self._active_phase = None

    def execute(self, request: Request) -> Result:
        with self._lock:
            if self._uncertain:
                return Result('blocked', error='target remains uncertain; no replay', uncertain=True)
            if self._active_request_id is not None:
                return Result('blocked', error='another C01 request remains in flight')
            if self._stop_requested:
                return Result('blocked', error='Stop latched; no later dispatch')
            if self._target is None or request.target != self._target:
                return Result('blocked', error='unattached or stale target; no fallback')
            if request.operation == 'download':
                return Result('not applicable', error='C01 has no dedicated download/save tool or destination control')
            if request.operation not in _TOOLS:
                return Result('not applicable', error='operation is outside the C01 allowlist')
            if not self._valid_deadline(request):
                return Result('blocked', error='missing or expired finite deadline')
            try:
                arguments = self._map_arguments(request)
            except (TypeError, ValueError) as error:
                return Result('blocked', error=str(error))
            self._active_request_id = request.request_id
            self._active_rpc_id = request.request_id + ':guard'
            self._active_phase = 'identity guard'
        try:
            observed = self._read_identity(request, 'guard')
            if isinstance(observed, Result):
                return observed
            with self._lock:
                if self._stop_requested:
                    return Result('blocked', error='Stop received during identity guard; action withheld', dispatched=True)
                if not self._valid_deadline(request):
                    return Result('blocked', error='deadline expired during identity guard; action withheld', dispatched=True)
                if not self._identity_matches(observed, request.target):
                    return Result('blocked', error='target changed before action; no fallback',
                                  dispatched=True, details={'observed_identity': observed})
                if request.operation == 'wait':
                    milliseconds = max(1, (request.deadline_ns - time.monotonic_ns()) // 1_000_000)
                    arguments['timeout'] = min(arguments.get('timeout', milliseconds), milliseconds)
                self._active_rpc_id = request.request_id
                self._active_phase = 'action'
            # The runner's atomic host dispatch gate closes the remaining gap
            # between this local check and transport write. This callable API
            # cannot prove that native-driver dispatch and Stop are atomic.
            response = self._rpc('tools/call', {'name': _TOOLS[request.operation], 'arguments': arguments},
                                 request.request_id, request.deadline_ns)
            if not isinstance(response, dict):
                raise TypeError('non-dictionary MCP result')
            if response.get('isError') is True:
                uncertain = request.operation in _MUTATIONS
                if uncertain:
                    self._uncertain = True
                return Result('failed', error='MCP tool reported error; inspect response',
                              value=response, uncertain=uncertain, dispatched=True)
            if response.get('isError') not in (None, False) or not isinstance(response.get('content'), list):
                raise ValueError('malformed MCP tool result')
            with self._lock:
                if self._uncertain:
                    return Result('failed', error='response arrived after Stop/uncertainty; no completion credit',
                                  value=response, uncertain=True, dispatched=True)
            return Result('passed', value=response, dispatched=True,
                          details={'identity_guard': observed,
                                   'limit': 'guard/action is not atomic in the driver'})
        except Exception as error:
            self._uncertain = True
            return Result('failed', error=f'{type(error).__name__}: {error}; no replay',
                          uncertain=True, dispatched=True)
        finally:
            with self._lock:
                if self._active_request_id == request.request_id:
                    self._active_request_id = self._active_rpc_id = self._active_phase = None

    def cancel(self, request_id: str) -> Result:
        with self._lock:
            if not request_id or request_id != self._active_request_id:
                return Result('not applicable', error='no matching in-flight C01 request; host Stop gate remains authoritative')
            phase = self._active_phase
            rpc_id = self._active_rpc_id
            self._stop_requested = True
            if phase == 'action':
                self._uncertain = True
            if self._notify is None:
                return Result('not applicable', error='transport has no cancellation notification route; Stop latched',
                              uncertain=self._uncertain, details={'phase': phase, 'action_withheld': phase != 'action'})
        try:
            self._notify('notifications/cancelled', {'requestId': rpc_id, 'reason': 'research Stop'})
            return Result('not applicable', error='notification sent; no ACK or browser-work cessation guarantee',
                          uncertain=self._uncertain, dispatched=True,
                          details={'notification_sent': True, 'phase': phase, 'cancelled_rpc_id': rpc_id,
                                   'action_withheld': phase != 'action', 'cancel_ack': None, 'cessation_verified': False})
        except Exception as error:
            if phase == 'action':
                self._uncertain = True
            return Result('failed', error=f'cancellation notification failed: {error}',
                          uncertain=self._uncertain, dispatched=True)

    def inspect_state(self) -> dict[str, Any]:
        with self._lock:
            return {'candidate_id': self.candidate_id, 'candidate_version': VERSION,
                    'attached_target': asdict(self._target) if self._target else None,
                    'in_flight_request_id': self._active_request_id,
                    'in_flight_rpc_id': self._active_rpc_id, 'phase': self._active_phase,
                    'stop_requested': self._stop_requested,
                    'uncertain': self._uncertain, 'artifact_verified': self._artifact is not None,
                    'cessation_verified': False,
                    'limit': 'local state only; this method makes no browser RPC'}

    def detach(self) -> Result:
        with self._lock:
            if self._active_request_id or self._uncertain:
                return Result('blocked', error='in-flight or uncertain work requires runner reconciliation',
                              uncertain=self._uncertain)
            self._target = None
        if self._close_owned_transport is None:
            return Result('passed', details={'scope': 'local target binding released; borrowed transport remains open',
                                             'browser_closed': False, 'cessation_verified': False})
        try:
            self._close_owned_transport()
            return Result('passed', details={'scope': 'caller-provided owned transport closed',
                                             'browser_closed': False, 'cessation_verified': False})
        except Exception as error:
            self._uncertain = True
            return Result('failed', error=f'owned transport cleanup failed: {error}', uncertain=True)

    def _prerequisite_error(self, request: Request) -> str | None:
        target = request.target
        if self._artifact is None:
            return 'pinned artifact not verified by preflight'
        if not self._binding_verified:
            return 'pinned runtime, page-ID routing and telemetry configuration not verified by owner'
        if not self._consent:
            return 'current Chrome debugging/connection consent absent or denied'
        if not self._profile or target.profile != self._profile:
            return 'current selected profile absent or different'
        if not all((target.run_id, target.generation, target.url, target.nonce, target.target_id)):
            return 'incomplete pre-attachment target identity'
        if not self._fixture_url(target):
            return 'target URL must be an exact loopback fixture page for its run'
        if not self._page_id(target.target_id):
            return 'target_id must be an explicit positive MCP page ID'
        if not self._valid_deadline(request):
            return 'missing or expired finite deadline'
        return None

    @staticmethod
    def _fixture_url(target: Target) -> bool:
        try:
            from urllib.parse import urlsplit
            url = urlsplit(target.url)
            segments = url.path.split('/')
            return (url.scheme == 'http' and url.hostname == '127.0.0.1' and
                    url.port is not None and not url.username and not url.password and
                    not url.query and not url.fragment and len(segments) == 3 and
                    segments[1] == target.run_id and segments[2] in {'A', 'B', 'decoy'})
        except (TypeError, ValueError):
            return False

    @staticmethod
    def _page_id(value: str) -> int | None:
        if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]*', value):
            return None
        return int(value)

    @staticmethod
    def _valid_deadline(request: Request) -> bool:
        return isinstance(request.deadline_ns, int) and not isinstance(request.deadline_ns, bool) and request.deadline_ns > time.monotonic_ns()

    def _read_identity(self, request: Request, suffix: str) -> dict[str, Any] | Result:
        try:
            response = self._rpc('tools/call', {'name': 'evaluate_script', 'arguments': {
                'pageId': self._page_id(request.target.target_id), 'function': _IDENTITY_FUNCTION,
                'waitForStableDom': False}}, request.request_id + ':' + suffix, request.deadline_ns)
            if not isinstance(response, dict):
                raise TypeError('non-dictionary identity result')
            if response.get('isError') is True:
                return Result('failed', error='identity read failed', value=response, dispatched=True)
            if response.get('isError') not in (None, False):
                raise ValueError('malformed identity response')
            content = response.get('content')
            if not isinstance(content, list):
                raise ValueError('identity response has no MCP content')
            text = '\n'.join(item.get('text', '') for item in content if isinstance(item, dict) and item.get('type') == 'text')
            if 'browser was restarted or reconnected' in text or 'Page ids have changed' in text:
                self._uncertain = True
                return Result('failed', error='driver reconnected; page IDs may have changed',
                              uncertain=True, dispatched=True)
            matches = _JSON_BLOCK.findall(text)
            if len(matches) != 1:
                raise ValueError('identity response lacks one JSON block')
            value = json.loads(matches[0])
            if not isinstance(value, dict):
                raise ValueError('identity response is not an object')
            return value
        except Exception as error:
            self._uncertain = True
            return Result('failed', error=f'identity transport/protocol failure: {error}; no replay',
                          uncertain=True, dispatched=True)

    @staticmethod
    def _identity_matches(observed: dict[str, Any], target: Target) -> bool:
        try:
            from urllib.parse import urlsplit
            expected_path = urlsplit(target.url).path.rstrip('/')
            expected_target = expected_path.rsplit('/', 1)[-1]
            return (observed.get('run_id') == target.run_id and
                    observed.get('generation') == target.generation and
                    observed.get('target') == expected_target and
                    observed.get('url') == target.url and
                    observed.get('nonce') == target.nonce and
                    observed.get('stored_nonce') == target.nonce)
        except (TypeError, ValueError):
            return False

    def _map_arguments(self, request: Request) -> dict[str, Any]:
        operation, source = request.operation, request.arguments
        if not isinstance(source, dict):
            raise TypeError('operation arguments must be an object')
        permitted = {
            'observe': {'verbose'}, 'click': {'uid', 'dblClick', 'includeSnapshot'},
            'fill': {'uid', 'value', 'includeSnapshot'},
            'evaluate': {'function', 'args', 'waitForStableDom'},
            'wait': {'text', 'timeout'}, 'upload': {'uid', 'filePaths', 'includeSnapshot'},
        }[operation]
        if set(source) - permitted:
            raise ValueError('unexpected native tool argument')
        args = dict(source)
        for key in {'uid', 'value', 'function'} & permitted:
            if key in {'uid', 'function'} and (not isinstance(args.get(key), str) or not args[key]):
                raise ValueError(f'{key} must be a nonempty string')
            if key == 'value' and not isinstance(args.get(key), str):
                raise ValueError('value must be a string')
        for key in {'verbose', 'dblClick', 'includeSnapshot', 'waitForStableDom'} & set(args):
            if not isinstance(args[key], bool):
                raise ValueError(f'{key} must be boolean')
        if operation == 'evaluate':
            if 'args' in args and (not isinstance(args['args'], list) or
                                   any(not isinstance(item, str) for item in args['args'])):
                raise ValueError('args must be a list of element UIDs')
        if operation == 'wait':
            if not isinstance(args.get('text'), list) or not args['text'] or any(
                    not isinstance(item, str) or not item for item in args['text']):
                raise ValueError('text must be a nonempty string list')
            if 'timeout' in args and (not isinstance(args['timeout'], int) or isinstance(args['timeout'], bool) or args['timeout'] <= 0):
                raise ValueError('timeout must be positive milliseconds')
        if operation == 'upload':
            paths = args.get('filePaths')
            if not isinstance(paths, list) or not paths or not self._upload_roots:
                raise ValueError('upload requires explicit synthetic file paths and allowed roots')
            for name in paths:
                if not isinstance(name, str) or not Path(name).is_absolute():
                    raise ValueError('upload path must be absolute')
                path = Path(name).resolve()
                if not path.is_file() or not any(path.is_relative_to(root) and root.is_relative_to(ROOT.resolve())
                                               for root in self._upload_roots):
                    raise ValueError('upload path outside declared synthetic roots')
        args['pageId'] = self._page_id(request.target.target_id)
        return args
