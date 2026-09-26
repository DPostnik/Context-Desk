"""Bounded JSON-RPC over one verified owned stdio child.

This transport does not attach to a browser. Its caller must supply a pinned,
reviewed executable/argument list and explicit consent before adapter attach.
"""
import json
import math
import os
from pathlib import Path
import selectors
import subprocess
import threading
import time
import uuid


class TransportError(RuntimeError):
    pass


class WireRejected(TransportError):
    """Host rejected an RPC before any transport bytes were written."""


class StdioRPC:
    def __init__(self, command, *, env=None, cwd=None, stderr_path=None, max_line=4_000_000):
        if not command or not all(isinstance(arg, str) and arg for arg in command):
            raise ValueError('explicit command required')
        self.command = list(command)
        self.env = env
        self.cwd = cwd
        self.stderr_path = Path(stderr_path) if stderr_path else None
        self.max_line = max_line
        self.process = None
        self._stderr = None
        self._reader = None
        self._write_lock = threading.Lock()
        self._lock = threading.RLock()
        self._pending = {}
        self._seen = set()
        self._late = []
        self._denied = []
        self._failure = None
        self._closed = False
        self.cleanup = []

    @property
    def late_responses(self):
        with self._lock:
            return list(self._late)

    @property
    def denied_server_messages(self):
        with self._lock:
            return list(self._denied)

    def start(self):
        if self.process is not None or self._closed:
            raise TransportError('transport already started or closed')
        if self.stderr_path:
            self.stderr_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._stderr = self.stderr_path.open('xb')
            os.chmod(self.stderr_path, 0o600)
        try:
            self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=self._stderr or subprocess.DEVNULL,
                cwd=self.cwd, env=self.env, bufsize=0)
        except BaseException:
            if self._stderr:
                self._stderr.close()
            raise
        self.cleanup.append({'owned_pid': self.process.pid, 'started_ns': time.monotonic_ns()})
        os.set_blocking(self.process.stdin.fileno(), False)
        self._reader = threading.Thread(target=self._read, name='research-stdio-reader', daemon=True)
        self._reader.start()
        return self

    def _fail(self, reason):
        with self._lock:
            if self._failure is None:
                self._failure = reason
            for event, _ in self._pending.values():
                event.set()

    def _send(self, value, deadline_ns):
        data = json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode() + b'\n'
        if len(data) > self.max_line:
            raise TransportError('outbound JSON-RPC line too large')
        remaining = max(0, (deadline_ns-time.monotonic_ns())/1e9)
        if not self._write_lock.acquire(timeout=remaining):
            raise TimeoutError('JSON-RPC write lock deadline; no replay')
        try:
            if self.process is None or self.process.poll() is not None or self._closed:
                raise TransportError('owned stdio child unavailable')
            if self._failure:
                raise TransportError(self._failure)
            try:
                offset = 0
                with selectors.DefaultSelector() as selector:
                    selector.register(self.process.stdin, selectors.EVENT_WRITE)
                    while offset < len(data):
                        remaining_ns = deadline_ns-time.monotonic_ns()
                        if remaining_ns <= 0:
                            raise TimeoutError('JSON-RPC write deadline; no replay')
                        remaining = remaining_ns/1e9
                        if not selector.select(remaining):
                            raise TimeoutError('JSON-RPC write deadline; no replay')
                        try:
                            offset += os.write(self.process.stdin.fileno(), data[offset:])
                        except BlockingIOError:
                            continue
            except TimeoutError:
                raise
            except (BrokenPipeError, OSError, ValueError) as error:
                raise TransportError(f'stdio write failed: {error}') from error
        finally:
            self._write_lock.release()

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(self.max_line + 1)
                if not line:
                    raise TransportError('stdio EOF; outcome may be uncertain')
                if len(line) > self.max_line or not line.endswith(b'\n'):
                    raise TransportError('oversized or unterminated JSON-RPC line')
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError) as error:
                    raise TransportError('malformed JSON-RPC') from error
                if not isinstance(message, dict) or message.get('jsonrpc') != '2.0':
                    raise TransportError('invalid JSON-RPC envelope')
                if 'method' in message:
                    with self._lock:
                        self._denied.append({'monotonic_ns': time.monotonic_ns(),
                                             'method': message.get('method'), 'id': message.get('id')})
                    if 'id' in message:
                        self._send({'jsonrpc': '2.0', 'id': message['id'],
                                    'error': {'code': -32601, 'message': 'Server requests not authorized'}},
                                   time.monotonic_ns() + 1_000_000_000)
                    raise TransportError('unexpected server request or notification denied')
                response_id = message.get('id')
                if response_id is None or ('result' in message) == ('error' in message):
                    raise TransportError('invalid JSON-RPC response')
                with self._lock:
                    pending = self._pending.get(response_id)
                    if pending is None:
                        self._late.append({'monotonic_ns': time.monotonic_ns(), 'id': response_id})
                    else:
                        pending[1].append(message)
                        pending[0].set()
        except BaseException as error:
            self._fail(f'{type(error).__name__}: {error}')

    def rpc(self, method, params, request_id, deadline_ns, *, wire_gate=None):
        """Adapter injection: rpc(method, params, request_id, deadline_ns)."""
        if not isinstance(method, str) or not method or not isinstance(params, dict):
            raise ValueError('method and params required')
        if not isinstance(request_id, (str, int)) or isinstance(request_id, bool):
            raise ValueError('request_id must be a string or integer')
        if deadline_ns <= time.monotonic_ns():
            raise TimeoutError('deadline passed before dispatch')
        event, box = threading.Event(), []
        with self._lock:
            if self._failure or self._closed or self.process is None:
                raise TransportError(self._failure or 'transport unavailable')
            if request_id in self._seen:
                raise TransportError('duplicate request ID; replay forbidden')
            self._seen.add(request_id)
            self._pending[request_id] = (event, box)
        try:
            if wire_gate is None:
                try:
                    self._send({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params}, deadline_ns)
                except BaseException as error:
                    self._fail(f'write outcome uncertain: {type(error).__name__}: {error}')
                    raise
            else:
                with wire_gate.admit(method, params, request_id, deadline_ns):
                    try:
                        self._send({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params}, deadline_ns)
                    except BaseException as error:
                        self._fail(f'write outcome uncertain: {type(error).__name__}: {error}')
                        raise
            remaining = max(0, (deadline_ns - time.monotonic_ns()) / 1e9)
            if not event.wait(remaining):
                raise TimeoutError('JSON-RPC deadline; no replay')
            with self._lock:
                if self._failure:
                    raise TransportError(self._failure)
            if not box:
                raise TransportError('response unavailable')
            message = box[0]
            if 'error' in message:
                raise TransportError(f'JSON-RPC error: {message["error"]}')
            return message['result']
        finally:
            with self._lock:
                self._pending.pop(request_id, None)

    __call__ = rpc

    def notify(self, method, params, *, deadline_ns=None):
        if not isinstance(method, str) or not method or not isinstance(params, dict):
            raise ValueError('method and params required')
        self._send({'jsonrpc': '2.0', 'method': method, 'params': params},
                   deadline_ns or time.monotonic_ns() + 5_000_000_000)

    def initialize_mcp(self, *, expected_server_version, protocol_version='2025-11-25',
                       seconds=10):
        """Bounded, browser-free MCP initialize + tool-catalog handshake."""
        if not expected_server_version or not isinstance(expected_server_version, str):
            raise ValueError('exact expected server version required')
        if protocol_version != '2025-11-25':
            raise ValueError('unpinned MCP protocol version')
        if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds <= 0 or seconds > 30:
            raise ValueError('finite handshake budget required')
        deadline = time.monotonic_ns() + int(seconds * 1e9)
        try:
            initialized = self.rpc('initialize', {
                'protocolVersion': protocol_version, 'capabilities': {},
                'clientInfo': {'name': 'context-desk-research-runner', 'version': '1'}},
                'initialize-' + uuid.uuid4().hex, deadline)
            if (not isinstance(initialized, dict)
                    or initialized.get('protocolVersion') != protocol_version
                    or initialized.get('serverInfo', {}).get('version') != expected_server_version):
                raise TransportError('MCP protocol/server version mismatch')
            self.notify('notifications/initialized', {}, deadline_ns=deadline)
            catalog = self.rpc('tools/list', {}, 'catalog-' + uuid.uuid4().hex, deadline)
            if (not isinstance(catalog, dict) or not isinstance(catalog.get('tools'), list)
                    or not catalog['tools'] or catalog.get('nextCursor')):
                raise TransportError('missing or unexpectedly paginated MCP tool catalog')
            names = [tool.get('name') if isinstance(tool, dict) else None for tool in catalog['tools']]
            if not all(isinstance(name, str) and name for name in names):
                raise TransportError('invalid MCP tool catalog entry')
            return {'initialized': initialized, 'tools': names}
        except BaseException:
            self.close()
            raise

    def close(self, *, grace_seconds=1.0):
        """Close only this Popen child; never its process group or a shared daemon."""
        with self._lock:
            self._closed = True
        self._fail('transport closed')
        child = self.process
        if child is None:
            return
        try:
            child.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            child.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=grace_seconds)
        if self.process.stdout:
            self.process.stdout.close()
        if self._reader:
            self._reader.join(timeout=grace_seconds)
        if self._stderr:
            self._stderr.close()
        self.cleanup.append({'owned_pid': child.pid, 'exit': child.returncode,
                             'reaped_ns': time.monotonic_ns(), 'scope': 'direct owned child only',
                             'reader_alive': bool(self._reader and self._reader.is_alive())})

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.close()
