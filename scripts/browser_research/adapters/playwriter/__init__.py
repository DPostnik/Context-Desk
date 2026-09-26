"""C03 Playwriter 0.7.0 extension/relay adapter; injected MCP transport only."""

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

from contract import Request, Result, Target
from evidence import ROOT


VERSION = '0.7.0'
HISTORICAL_EXTENSION = '0.0.148'  # Historical Gate 0 evidence, never a current grant.
ARTIFACT_INTEGRITY = 'nKKJyCch0vYmpTpi9g7fpYF9rDDfGwXxuNQ32vK9dXrtVOjIsZaEnfsYH1uptPwsRl82V7fdwUyRrsfVkMw45w=='
SOURCE_ROOT = ROOT.parent / 'research-2026-09-26-stage12'
_IDENTITY_LINE = re.compile(r'(?m)^\[log\] __CDR_ID__(\{[^\n]*\})$')
_VALUE_LINE = re.compile(r'(?m)^\[log\] __CDR_VALUE__(.+)$')
_OPERATIONS = {'observe', 'click', 'fill', 'evaluate', 'wait', 'upload', 'download'}
_MUTATIONS = {'click', 'fill', 'evaluate', 'upload', 'download'}


class PlaywriterAdapter:
    candidate_id = 'C03'
    candidate_version = VERSION

    def __init__(self, rpc: Callable, notify: Callable | None = None, *,
                 browser_consent: bool = False, current_profile: str | None = None,
                 runtime_binding_verified: bool = False,
                 dependency_lock_verified: bool = False,
                 current_extension_verified: bool = False,
                 selected_tabs_verified: bool = False,
                 relay_ownership_verified: bool = False,
                 explicit_relay_host: bool = False,
                 auto_enable_disabled: bool = False,
                 direct_cdp_disabled: bool = False,
                 artifact_root: Path = SOURCE_ROOT,
                 allowed_upload_roots: tuple[Path, ...] = (),
                 allowed_download_roots: tuple[Path, ...] = (),
                 close_owned_transport: Callable | None = None):
        self._rpc = rpc
        self._notify = notify
        self._profile = current_profile
        self._prerequisites = {
            'current extension attachment approval': browser_consent,
            'pinned runtime transport binding': runtime_binding_verified,
            'exact transitive dependency lock': dependency_lock_verified,
            'current installed extension identity': current_extension_verified,
            'explicit selected extension tabs': selected_tabs_verified,
            'relay process ownership and endpoint': relay_ownership_verified,
            'explicit PLAYWRITER_HOST relay route': explicit_relay_host,
            'PLAYWRITER_AUTO_ENABLE=false': auto_enable_disabled,
            'PLAYWRITER_DIRECT unset': direct_cdp_disabled,
        }
        self._artifact_root = Path(artifact_root)
        self._upload_roots = tuple(Path(p).resolve() for p in allowed_upload_roots)
        self._download_roots = tuple(Path(p).resolve() for p in allowed_download_roots)
        self._close_owned_transport = close_owned_transport
        self._artifact: dict[str, Any] | None = None
        self._target: Target | None = None
        self._lock = threading.RLock()
        self._active_request_id: str | None = None
        self._active_rpc_id: str | None = None
        self._phase: str | None = None
        self._stop = False
        self._uncertain = False

    def preflight(self) -> Result:
        """Verify retained source archive only; no relay or extension call."""
        archive = self._artifact_root / 'playwriter-package.tgz'
        try:
            raw = archive.read_bytes()
            if base64.b64encode(hashlib.sha512(raw).digest()).decode() != ARTIFACT_INTEGRITY:
                raise ValueError('published 0.7.0 archive integrity mismatch')
            with tarfile.open(archive) as tar:
                files = [m for m in tar.getmembers() if m.isfile()]
                if len(files) != 498:
                    raise ValueError('unexpected 0.7.0 file count')
                names = set()
                matched = set()
                for member in files:
                    name = Path(member.name)
                    if name.is_absolute() or '..' in name.parts or name in names:
                        raise ValueError('unsafe or duplicate package entry')
                    names.add(name)
                    relative = Path(*name.parts[1:]) if name.parts[0] == 'package' else None
                    if relative is None:
                        raise ValueError('unexpected archive root')
                    path = self._artifact_root / 'playwriter-package' / relative
                    if path.is_symlink() or not path.resolve().is_relative_to((self._artifact_root / 'playwriter-package').resolve()):
                        raise ValueError('unsafe extracted path')
                    # Stage 1–2 extracted selected text files, not every asset.
                    if path.exists():
                        if hashlib.sha256(tar.extractfile(member).read()).digest() != hashlib.sha256(path.read_bytes()).digest():
                            raise ValueError('extracted source mismatch')
                        matched.add(relative.as_posix())
                required = {'package.json', 'src/mcp.ts', 'src/executor.ts',
                            'src/cdp-relay.ts', 'src/cdp-session.ts', 'src/utils.ts'}
                if not required.issubset(matched):
                    raise ValueError('selected source files missing')
            manifest = json.loads((self._artifact_root / 'playwriter-package/package.json').read_text())
            if manifest.get('version') != VERSION or manifest.get('name') != 'playwriter':
                raise ValueError('package manifest mismatch')
            self._artifact = {'archive_sha512': ARTIFACT_INTEGRITY, 'files': len(files),
                              'selected_files_verified': len(matched),
                              'path': str(self._artifact_root / 'playwriter-package')}
            return Result('passed', value=self._artifact, details={
                'scope': 'retained npm source only',
                'runtime_lock': 'unverified; ^ dependency ranges are not a lock',
                'extension': f'{HISTORICAL_EXTENSION} historical only'})
        except (OSError, ValueError, tarfile.TarError, json.JSONDecodeError) as error:
            self._artifact = None
            return Result('blocked', error=f'Playwriter source artifact: {error}')

    def attach(self, request: Request) -> Result:
        with self._lock:
            if self._target or self._active_request_id or self._stop or self._uncertain:
                return Result('blocked', error='active/attached/Stopped/uncertain adapter state', uncertain=self._uncertain)
            missing = self._missing_prerequisite(request)
            if missing:
                return Result('blocked', error=missing)
            if request.operation != 'attach' or request.arguments:
                return Result('failed', error='attach accepts no arguments')
            self._set_active(request.request_id, request.request_id + ':attach', 'identity guard')
        try:
            response = self._call_script(request, request.request_id + ':attach', self._guard_code(request.target), action=False)
            if isinstance(response, Result):
                return response
            identity = self._parse_identity(response)
            with self._lock:
                if self._stop:
                    return Result('blocked', error='Stop during attach; no target admitted', dispatched=True)
                if not self._identity_matches(identity, request.target):
                    return Result('blocked', error='fixture/CDP target identity mismatch', dispatched=True,
                                  details={'observed_identity': identity})
                self._target = request.target
            return Result('passed', value=identity, dispatched=True,
                          details={'route': 'existing extension relay; no reset or tab creation',
                                   'browser_wide_visibility': 'connected extension tabs may be visible; host binding is not driver isolation'})
        except (ValueError, TypeError) as error:
            self._uncertain = True
            return Result('failed', error=f'identity protocol response: {error}; no replay',
                          uncertain=True, dispatched=True)
        finally:
            self._clear_active(request.request_id)

    def execute(self, request: Request) -> Result:
        with self._lock:
            if self._stop or self._uncertain:
                return Result('blocked', error='Stop/uncertainty latched; no replay', uncertain=self._uncertain)
            if self._active_request_id:
                return Result('blocked', error='another Playwriter request active')
            if self._target is None or request.target != self._target:
                return Result('blocked', error='unattached/stale target; no fallback')
            if request.operation not in _OPERATIONS:
                return Result('not applicable', error='operation outside C03 allowlist')
            if not self._deadline_ok(request):
                return Result('blocked', error='missing or expired finite deadline')
            try:
                action = self._action_code(request)
            except (TypeError, ValueError) as error:
                return Result('blocked', error=str(error))
            self._set_active(request.request_id, request.request_id + ':guard', 'identity guard')
        try:
            first = self._call_script(request, request.request_id + ':guard', self._guard_code(request.target), action=False)
            if isinstance(first, Result):
                return first
            identity = self._parse_identity(first)
            with self._lock:
                if self._stop:
                    return Result('blocked', error='Stop during guard; action withheld', dispatched=True)
                if not self._deadline_ok(request):
                    return Result('blocked', error='deadline expired during guard; action withheld', dispatched=True)
                if not self._identity_matches(identity, request.target):
                    return Result('blocked', error='target changed before action', dispatched=True,
                                  details={'observed_identity': identity})
                self._active_rpc_id = request.request_id
                self._phase = 'action'
            # Host wire gate must serialize the actual transport write with Stop.
            # The action script repeats the guard but Playwriter does not consume
            # MCP cancellation as a demonstrated browser cessation primitive.
            response = self._call_script(request, request.request_id,
                                         self._guard_code(request.target) + action, action=True)
            if isinstance(response, Result):
                return response
            second = self._parse_identity(response)
            if not self._identity_matches(second, request.target):
                self._uncertain = True
                return Result('failed', error='action response identity mismatch; effect uncertain',
                              uncertain=True, dispatched=True)
            value = self._parse_value(response)
            with self._lock:
                if self._stop or self._uncertain:
                    return Result('failed', error='late response after Stop/uncertainty', uncertain=True,
                                  dispatched=True, value=value)
            return Result('passed', value=value, dispatched=True,
                          details={'identity_guard': second, 'runtime_limit': 'source mapping, browser behavior untested'})
        except (TypeError, ValueError) as error:
            self._uncertain = True
            return Result('failed', error=f'Playwriter response/protocol failure: {error}; no replay',
                          uncertain=True, dispatched=True)
        finally:
            self._clear_active(request.request_id)

    def cancel(self, request_id: str) -> Result:
        with self._lock:
            if not request_id or request_id != self._active_request_id:
                return Result('not applicable', error='no matching active request; host Stop gate remains authoritative')
            phase, rpc_id = self._phase, self._active_rpc_id
            self._stop = True
            if phase == 'action':
                self._uncertain = True
        if self._notify is None:
            return Result('not applicable', error='Playwriter execute has no verified cancellation route; Stop latched',
                          uncertain=self._uncertain, details={'phase': phase, 'action_withheld': phase != 'action'})
        try:
            self._notify('notifications/cancelled', {'requestId': rpc_id, 'reason': 'research Stop'})
            return Result('not applicable', error='MCP notification sent; no ACK or cessation claim',
                          uncertain=self._uncertain, dispatched=True,
                          details={'notification_sent': True, 'cancelled_rpc_id': rpc_id, 'phase': phase,
                                   'action_withheld': phase != 'action',
                                   'cancel_ack': None, 'cessation_verified': False})
        except Exception as error:
            return Result('failed', error=f'cancellation notification transport failed: {error}',
                          uncertain=self._uncertain, dispatched=True)

    def inspect_state(self) -> dict[str, Any]:
        with self._lock:
            return {'candidate_id': 'C03', 'candidate_version': VERSION,
                    'attached_target': asdict(self._target) if self._target else None,
                    'in_flight_request_id': self._active_request_id,
                    'in_flight_rpc_id': self._active_rpc_id, 'phase': self._phase,
                    'stop_requested': self._stop, 'uncertain': self._uncertain,
                    'artifact_verified': self._artifact is not None,
                    'cessation_verified': False, 'browser_rpc': False}

    def detach(self) -> Result:
        with self._lock:
            if self._active_request_id or self._uncertain:
                return Result('blocked', error='in-flight or uncertain work needs independent reconciliation',
                              uncertain=self._uncertain)
            self._target = None
        if self._close_owned_transport is None:
            return Result('passed', details={'scope': 'local binding only; borrowed MCP/relay/browser remain',
                                             'browser_closed': False, 'cessation_verified': False})
        try:
            self._close_owned_transport()
            return Result('passed', details={'scope': 'verified caller-owned MCP transport only',
                                             'relay_closed': False, 'browser_closed': False,
                                             'cessation_verified': False})
        except Exception as error:
            self._uncertain = True
            return Result('failed', error=f'owned transport cleanup failed: {error}', uncertain=True)

    def _missing_prerequisite(self, request: Request) -> str | None:
        if self._artifact is None:
            return 'retained Playwriter 0.7.0 source not verified'
        for name, value in self._prerequisites.items():
            if not value:
                return f'missing {name}'
        target = request.target
        if not self._profile or target.profile != self._profile:
            return 'current selected browser profile absent/different'
        if not all((target.run_id, target.generation, target.url, target.nonce, target.target_id)):
            return 'incomplete pre-attachment target identity'
        if not self._fixture_url(target):
            return 'target must be exact loopback fixture A/B/decoy URL'
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', target.target_id):
            return 'target_id must be explicit CDP target ID'
        if not self._deadline_ok(request):
            return 'missing or expired finite deadline'
        return None

    @staticmethod
    def _fixture_url(target: Target) -> bool:
        try:
            from urllib.parse import urlsplit
            u = urlsplit(target.url)
            pieces = u.path.split('/')
            return (u.scheme == 'http' and u.hostname == '127.0.0.1' and u.port is not None and
                    not u.username and not u.password and not u.query and not u.fragment and
                    len(pieces) == 3 and pieces[1] == target.run_id and pieces[2] in {'A', 'B', 'decoy'})
        except (TypeError, ValueError):
            return False

    @staticmethod
    def _deadline_ok(request: Request) -> bool:
        return isinstance(request.deadline_ns, int) and not isinstance(request.deadline_ns, bool) and request.deadline_ns > time.monotonic_ns()

    def _set_active(self, parent_id: str, rpc_id: str, phase: str):
        self._active_request_id, self._active_rpc_id, self._phase = parent_id, rpc_id, phase

    def _clear_active(self, parent_id: str):
        with self._lock:
            if self._active_request_id == parent_id:
                self._active_request_id = self._active_rpc_id = self._phase = None

    def _call_script(self, request: Request, rpc_id: str, code: str, *, action: bool) -> dict | Result:
        remaining_ms = max(1, (request.deadline_ns - time.monotonic_ns()) // 1_000_000)
        requested = request.arguments.get('timeout') if action and isinstance(request.arguments, dict) else None
        timeout = min(remaining_ms, requested) if isinstance(requested, int) and requested > 0 else remaining_ms
        try:
            response = self._rpc('tools/call', {'name': 'execute', 'arguments': {'code': code, 'timeout': timeout}},
                                 rpc_id, request.deadline_ns)
            if not isinstance(response, dict) or not isinstance(response.get('content'), list):
                raise ValueError('malformed MCP tool result')
            if response.get('isError') is True:
                if action:
                    self._uncertain = True
                return Result('failed', error='Playwriter execute reported error; no reset/replay',
                              value=response, uncertain=action, dispatched=True)
            if response.get('isError') not in (None, False):
                raise ValueError('malformed MCP isError')
            return response
        except Exception as error:
            self._uncertain = True
            return Result('failed', error=f'{type(error).__name__}: {error}; no replay',
                          uncertain=True, dispatched=True)

    @staticmethod
    def _text(response: dict) -> str:
        return '\n'.join(block.get('text', '') for block in response['content']
                         if isinstance(block, dict) and block.get('type') == 'text')

    def _parse_identity(self, response: dict) -> dict[str, Any]:
        matches = _IDENTITY_LINE.findall(self._text(response))
        if len(matches) != 1:
            raise ValueError('missing/duplicate Playwriter identity marker')
        value = json.loads(matches[0])
        if not isinstance(value, dict):
            raise ValueError('identity is not an object')
        return value

    def _parse_value(self, response: dict) -> Any:
        matches = _VALUE_LINE.findall(self._text(response))
        if len(matches) != 1:
            raise ValueError('missing/duplicate Playwriter value marker; output may be truncated')
        return json.loads(matches[0])

    @staticmethod
    def _identity_matches(value: dict[str, Any], target: Target) -> bool:
        return (value.get('run_id') == target.run_id and
                value.get('generation') == target.generation and
                value.get('target') == target.url.rsplit('/', 1)[-1] and
                value.get('url') == target.url and
                value.get('nonce') == target.nonce and
                value.get('stored_nonce') == target.nonce and
                value.get('target_id') == target.target_id)

    @staticmethod
    def _guard_code(target: Target) -> str:
        expected = json.dumps({'run_id': target.run_id, 'generation': target.generation,
                               'target': target.url.rsplit('/', 1)[-1], 'url': target.url,
                               'nonce': target.nonce, 'stored_nonce': target.nonce,
                               'target_id': target.target_id}, ensure_ascii=True)
        url = json.dumps(target.url)
        return (f'const __cdExpected={expected};'
                f'const __cdPages=context.pages().filter(p=>!p.isClosed()&&p.url()==={url});'
                'if(__cdPages.length!==1)throw Error("C03 exact page unavailable/ambiguous");'
                'const __cdPage=__cdPages[0];'
                'const __cdSession=await getCDPSession({page:__cdPage});'
                'const __cdInfo=(await __cdSession.send("Target.getTargetInfo")).targetInfo;'
                'const __cdFixture=await __cdPage.evaluate(()=>{const c=window.CONFIG;'
                'return {run_id:c?.run,generation:c?.generation,target:c?.target,'
                'nonce:window.fixtureSessionNonce,stored_nonce:c?sessionStorage.getItem(`research-${c.run}-${c.target}`):null}});'
                'const __cdIdentity={...__cdFixture,url:__cdPage.url(),target_id:__cdInfo?.targetId};'
                'console.log("__CDR_ID__"+JSON.stringify(__cdIdentity));'
                'if(Object.keys(__cdExpected).some(k=>__cdIdentity[k]!==__cdExpected[k]))'
                'throw Error("C03 fixture/CDP identity mismatch");')

    def _action_code(self, request: Request) -> str:
        args = request.arguments
        if not isinstance(args, dict):
            raise TypeError('arguments must be an object')
        operation = request.operation
        allowed = {
            'observe': {'timeout'}, 'click': {'selector', 'timeout'},
            'fill': {'selector', 'value', 'timeout'},
            'evaluate': {'function', 'arg', 'timeout'},
            'wait': {'text', 'timeout'},
            'upload': {'selector', 'filePaths', 'timeout'},
            'download': {'selector', 'saveAs', 'timeout'},
        }[operation]
        if set(args) - allowed:
            raise ValueError('unexpected native Playwriter argument')
        if 'timeout' in args and (not isinstance(args['timeout'], int) or isinstance(args['timeout'], bool) or args['timeout'] <= 0):
            raise ValueError('timeout must be positive milliseconds')
        for key in {'selector', 'text', 'function'} & allowed:
            if not isinstance(args.get(key), str) or not args[key]:
                raise ValueError(f'{key} must be nonempty string')
        if operation == 'fill' and not isinstance(args.get('value'), str):
            raise ValueError('value must be a string')
        if operation == 'evaluate' and 'arg' in args:
            try:
                json.dumps(args['arg'], allow_nan=False)
            except (TypeError, ValueError) as error:
                raise ValueError(f'arg must be JSON value: {error}') from error
        if operation == 'upload':
            paths = args.get('filePaths')
            if not isinstance(paths, list) or not paths or not self._upload_roots:
                raise ValueError('upload requires declared synthetic roots and filePaths')
            for name in paths:
                if not isinstance(name, str) or not Path(name).is_absolute():
                    raise ValueError('upload paths must be absolute')
                path = Path(name).resolve()
                if not path.is_file() or not any(root.is_relative_to(ROOT.resolve()) and path.is_relative_to(root)
                                               for root in self._upload_roots):
                    raise ValueError('upload path outside app-owned synthetic roots')
        if operation == 'download':
            name = args.get('saveAs')
            if not isinstance(name, str) or not Path(name).is_absolute() or not self._download_roots:
                raise ValueError('download requires absolute saveAs under declared app-owned root')
            path = Path(name).resolve()
            if path.exists() or not path.parent.is_dir() or not any(
                    root.is_relative_to(ROOT.resolve()) and path.is_relative_to(root)
                    for root in self._download_roots):
                raise ValueError('download destination exists or is outside declared root')
        timeout = max(1, min(args.get('timeout', 30_000), (request.deadline_ns - time.monotonic_ns()) // 1_000_000))
        if operation == 'observe':
            body = 'const __cdValue=await __cdPage.locator("body").ariaSnapshot();'
        elif operation == 'click':
            body = f'await __cdPage.locator({json.dumps(args["selector"])}).click({{timeout:{timeout}}});const __cdValue={{clicked:true}};'
        elif operation == 'fill':
            body = (f'await __cdPage.locator({json.dumps(args["selector"])}).fill({json.dumps(args["value"])},'
                    f'{{timeout:{timeout}}});const __cdValue={{filled:true}};')
        elif operation == 'evaluate':
            source_and_arg = json.dumps({'source': args['function'], 'argument': args.get('arg')}, ensure_ascii=True)
            page_wrapper = ('({source, argument}) => {'
                            'const fn = (0, eval)("(" + source + ")");'
                            'if (typeof fn !== "function") throw Error("evaluate source must be a function");'
                            'return fn(argument);'
                            '}')
            body = f'const __cdValue=await __cdPage.evaluate({page_wrapper},{source_and_arg});'
        elif operation == 'wait':
            body = (f'await __cdPage.getByText({json.dumps(args["text"])}).waitFor('
                    f'{{state:"visible",timeout:{timeout}}});const __cdValue={{visible:true}};')
        elif operation == 'upload':
            body = (f'await __cdPage.locator({json.dumps(args["selector"])}).setInputFiles('
                    f'{json.dumps(args["filePaths"])});const __cdValue={{uploaded:true}};')
        else:
            body = (f'const [__cdDownload]=await Promise.all([__cdPage.waitForEvent("download",{{timeout:{timeout}}}),'
                    f'__cdPage.locator({json.dumps(args["selector"])}).click({{timeout:{timeout}}})]);'
                    f'await __cdDownload.saveAs({json.dumps(args["saveAs"])});'
                    f'const __cdValue={{saveAs:{json.dumps(args["saveAs"])},'
                    'suggestedFilename:__cdDownload.suggestedFilename()};')
        return body + 'console.log("__CDR_VALUE__"+JSON.stringify(__cdValue));'
