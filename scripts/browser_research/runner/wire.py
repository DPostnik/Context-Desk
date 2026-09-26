"""Atomic host admission for every adapter tools/call stdio write."""
from contextlib import contextmanager
import re
import threading
import time

from contract import Request, Target
from .stdio import StdioRPC, WireRejected


class WireGate:
    """Bind an adapter's injected rpc to one runner and one owned stdio child.

    The gate audits actual JSON-RPC write admission. Driver execution after a
    previously admitted write remains uncertain until independently reconciled.
    """
    def __init__(self, transport: StdioRPC, target: Target):
        if not isinstance(transport, StdioRPC):
            raise TypeError('atomic wire gate requires StdioRPC transport')
        self.transport = transport
        self.target = target
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._active = None
        self.audit = []

    def _record(self, kind, **fields):
        self.audit.append({'monotonic_ns': time.monotonic_ns(), 'kind': kind, **fields})

    def begin(self, request: Request):
        with self._lock:
            if self._stop.is_set() or self._active is not None or request.target != self.target:
                raise WireRejected('wire target stopped, stale or busy')
            self._active = request
            self._record('wire_request_active', request_id=request.request_id,
                         run_id=self.target.run_id, target_generation=self.target.generation)

    def end(self, request: Request):
        with self._lock:
            if self._active == request:
                self._active = None
            self._record('wire_request_ended', request_id=request.request_id)

    def stop_intent(self):
        self._stop.set()
        self._record('wire_stop_intent')

    @contextmanager
    def admit(self, method, params, request_id, deadline_ns):
        remaining = max(0, (deadline_ns-time.monotonic_ns())/1e9)
        if not self._lock.acquire(timeout=remaining):
            raise TimeoutError('wire admission deadline')
        try:
            request = self._active
            valid_id = (request is not None and isinstance(request_id, str)
                        and re.fullmatch(re.escape(request.request_id) + r'(?::[A-Za-z0-9_-]+)?', request_id))
            valid_tool = (method == 'tools/call' and isinstance(params, dict)
                          and isinstance(params.get('name'), str)
                          and isinstance(params.get('arguments'), dict))
            if (self._stop.is_set() or not valid_id or not valid_tool
                    or request.target != self.target or deadline_ns != request.deadline_ns
                    or deadline_ns <= time.monotonic_ns()):
                self._record('wire_rejected', request_id=request_id, method=method,
                             reason='Stop, identity, method or deadline mismatch', dispatched=False)
                raise WireRejected('host wire admission rejected')
            self._record('wire_admitted', request_id=request_id, method=method,
                         tool=params['name'], run_id=self.target.run_id,
                         target_generation=self.target.generation,
                         deadline_ns=deadline_ns, dispatched=True)
            try:
                yield
            except BaseException as error:
                self._record('wire_write_failed_or_partial', request_id=request_id,
                             error=f'{type(error).__name__}: {error}', outcome_uncertain=True)
                raise
            else:
                self._record('wire_written', request_id=request_id, method=method,
                             tool=params['name'])
        finally:
            self._lock.release()

    def rpc(self, method, params, request_id, deadline_ns):
        return self.transport.rpc(method, params, request_id, deadline_ns, wire_gate=self)

    def notify(self, method, params):
        if method != 'notifications/cancelled' or not isinstance(params, dict):
            raise WireRejected('only cancellation notification allowed')
        self._record('wire_cancel_notification_attempt', request_id=params.get('requestId'))
        self.transport.notify(method, params)
        self._record('wire_cancel_notification_written', request_id=params.get('requestId'))
