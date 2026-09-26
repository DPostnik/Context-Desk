"""Host admission, deadline and Stop audit for contract-v1 adapters."""
from dataclasses import asdict
import json
import math
import threading
import time
from urllib.parse import urlsplit
import uuid

from contract import (CASE_SECONDS, CONTRACT_VERSION, POST_CANCEL_SECONDS,
                      WATCHDOG_SECONDS, Request, Result, Target)
from evidence import private_json, record


class RunnerError(RuntimeError):
    pass


class DirectRunner:
    """One frozen target and run generation; no implicit retry or target fallback.

    The runner is a host-side research gate, not proof that a browser process
    stopped. A caller must independently verify effects and reconcile uncertainty.
    """
    def __init__(self, adapter, target: Target, *, owned_transports=(),
                 wire_gate=None, case_seconds=CASE_SECONDS, watchdog_seconds=WATCHDOG_SECONDS):
        if not isinstance(target, Target) or not all(isinstance(v, str) and v for v in asdict(target).values()):
            raise ValueError('complete frozen Target required')
        if (not math.isfinite(case_seconds) or not math.isfinite(watchdog_seconds)
                or case_seconds <= 0 or watchdog_seconds <= 0 or case_seconds > watchdog_seconds):
            raise ValueError('finite case/watchdog limits required')
        url = urlsplit(target.url)
        if (url.scheme != 'http' or url.hostname not in {'127.0.0.1', 'localhost'}
                or url.port is None or url.username or url.password
                or url.path not in {f'/{target.run_id}/{name}' for name in ('A', 'B', 'decoy')}
                or url.query or url.fragment):
            raise ValueError('target URL must identify this loopback fixture run')
        self.adapter = adapter
        self.target = target
        self.run_generation = uuid.uuid4().hex
        self.owned_transports = tuple(owned_transports)
        if wire_gate is not None and wire_gate.target != target:
            raise ValueError('wire gate target mismatch')
        self.wire_gate = wire_gate
        self.case_seconds = case_seconds
        self.watchdog_seconds = watchdog_seconds
        self.audit = []
        self.timestamps = {k: None for k in ('dispatch', 'stop_received', 'cancel_sent',
            'cancel_ack', 'last_executor_effect', 'cessation_verified')}
        self._lock = threading.RLock()
        self._serial = threading.Lock()
        self._active = None
        self._admitted = False
        self._attached = False
        self._effect_possible = False
        self._stopped = False
        self._uncertain = False
        self._closed = False
        self._reconciliation = None
        self._post_cancel_observation = None
        self._started_ns = time.monotonic_ns()
        self._watchdog_ns = self._started_ns + int(watchdog_seconds * 1e9)
        self.cleanup = []

    @property
    def uncertain(self):
        with self._lock:
            return self._uncertain

    @property
    def stopped(self):
        with self._lock:
            return self._stopped

    def _event(self, kind, **fields):
        with self._lock:
            item = {'monotonic_ns': time.monotonic_ns(), 'kind': kind,
                    'run_generation': self.run_generation, **fields}
            self.audit.append(item)
            return item

    def _reject(self, reason, *, request_id=None, operation=None):
        self._event('rejected', request_id=request_id, operation=operation, reason=reason,
                    dispatched=False)
        return Result('blocked', error=reason, dispatched=False,
                      uncertain=self._uncertain)

    def _latch_uncertain(self):
        with self._lock:
            if self.wire_gate:
                self.wire_gate.stop_intent()
            self._uncertain = True
            self._stopped = True
            if self.timestamps['stop_received'] is None:
                self.timestamps['stop_received'] = time.monotonic_ns()

    def _invoke(self, operation, call, request, deadline_ns):
        """Bound a synchronous adapter call even if the adapter ignores its deadline."""
        event, box = threading.Event(), []
        def worker():
            try:
                value = call()
                box.append(value)
            except BaseException as error:
                box.append(error)
            finally:
                with self._lock:
                    if self._stopped or self._uncertain:
                        self._event('late_adapter_completion', request_id=request.request_id,
                                    operation=operation, ignored=True)
                    if self._active == request:
                        self._active = None
                    if self.wire_gate and operation != 'preflight':
                        self.wire_gate.end(request)
                event.set()
        with self._lock:
            if self._stopped or self._closed or deadline_ns <= time.monotonic_ns():
                return self._reject('Stop or deadline before adapter invocation',
                                    request_id=request.request_id, operation=operation)
            if self.wire_gate and operation != 'preflight':
                try:
                    self.wire_gate.begin(request)
                except BaseException as error:
                    return self._reject(f'wire gate denied invocation: {error}',
                                        request_id=request.request_id, operation=operation)
            self._active = request
            if operation not in {'preflight', 'attach', 'observe', 'detach'}:
                self._effect_possible = True
            self.timestamps['dispatch'] = time.monotonic_ns()
            self._event('dispatched', request_id=request.request_id, operation=operation,
                        target_generation=self.target.generation, deadline_ns=deadline_ns,
                        dispatched=True)
            thread = threading.Thread(target=worker, name=f'research-{operation}', daemon=True)
            thread.start()
        if not event.wait(max(0, (deadline_ns - time.monotonic_ns()) / 1e9)):
            self._latch_uncertain()
            self._event('deadline', request_id=request.request_id, operation=operation,
                        reason='adapter did not finish before finite deadline')
            self._cancel(request.request_id)
            return Result('failed', error='finite deadline exceeded', uncertain=True,
                          dispatched=True, details={'request_id': request.request_id})
        with self._lock:
            stopped = self._stopped
        if stopped:
            self._latch_uncertain()
            return Result('failed', error='Stop received; adapter result ignored', uncertain=True,
                          dispatched=True, details={'request_id': request.request_id})
        value = box[0]
        if isinstance(value, BaseException):
            self._latch_uncertain()
            self._event('adapter_error', request_id=request.request_id,
                        error=f'{type(value).__name__}: {value}', uncertain=True)
            return Result('failed', error=f'{type(value).__name__}: {value}',
                          uncertain=True, dispatched=True)
        if not isinstance(value, Result):
            self._latch_uncertain()
            self._event('invalid_result', request_id=request.request_id, uncertain=True)
            return Result('failed', error='adapter returned non-Result', uncertain=True, dispatched=True)
        if value.uncertain:
            self._latch_uncertain()
        self._event('result', request_id=request.request_id, status=value.status,
                    uncertain=value.uncertain, adapter_dispatched=value.dispatched)
        return value

    def _request(self, operation, arguments, deadline_ns):
        return Request(uuid.uuid4().hex, self.target, operation, arguments, deadline_ns)

    def _deadline(self, seconds):
        return min(time.monotonic_ns() + int(seconds * 1e9), self._watchdog_ns)

    def preflight(self):
        if not self._serial.acquire(timeout=max(0, (self._watchdog_ns-time.monotonic_ns())/1e9)):
            return self._reject('serial admission deadline', operation='preflight')
        try:
            with self._lock:
                if self._closed or self._stopped or self._admitted:
                    return self._reject('preflight unavailable', operation='preflight')
                deadline = self._deadline(self.case_seconds)
                if deadline <= time.monotonic_ns():
                    return self._reject('watchdog expired', operation='preflight')
                request = self._request('preflight', {}, deadline)
            result = self._invoke('preflight', self.adapter.preflight, request, deadline)
            with self._lock:
                self._admitted = result.status == 'passed' and not result.uncertain
            return result
        finally:
            self._serial.release()

    def attach(self):
        if not self._serial.acquire(timeout=max(0, (self._watchdog_ns-time.monotonic_ns())/1e9)):
            return self._reject('serial admission deadline', operation='attach')
        try:
            with self._lock:
                if self._closed or self._stopped or not self._admitted or self._attached:
                    return self._reject('attach not admitted', operation='attach')
                deadline = self._deadline(self.case_seconds)
                if deadline <= time.monotonic_ns():
                    return self._reject('watchdog expired', operation='attach')
                request = self._request('attach', {}, deadline)
            result = self._invoke('attach', lambda: self.adapter.attach(request), request, deadline)
            with self._lock:
                self._attached = result.status == 'passed' and not result.uncertain
            return result
        finally:
            self._serial.release()

    def dispatch(self, operation, arguments=None, *, target=None):
        """Admit exactly one adapter operation; rejected calls never reach it."""
        arguments = {} if arguments is None else arguments
        if not self._serial.acquire(timeout=max(0, (self._watchdog_ns-time.monotonic_ns())/1e9)):
            return self._reject('serial admission deadline', operation=operation)
        try:
            with self._lock:
                if target is not None and target != self.target:
                    return self._reject('stale or unselected target', operation=operation)
                if self._closed or self._stopped or self._uncertain:
                    return self._reject('run stopped or uncertain', operation=operation)
                if not self._attached:
                    return self._reject('target not attached', operation=operation)
                if not isinstance(arguments, dict):
                    return self._reject('arguments must be a dictionary', operation=operation)
                if operation not in {'observe', 'click', 'fill', 'evaluate', 'wait', 'upload', 'download'}:
                    return self._reject('unsupported operation', operation=operation)
                deadline = self._deadline(self.case_seconds)
                if deadline <= time.monotonic_ns():
                    self._latch_uncertain()
                    return self._reject('watchdog expired; outcome requires reconciliation', operation=operation)
                request = self._request(operation, dict(arguments), deadline)
            return self._invoke(operation, lambda: self.adapter.execute(request), request, deadline)
        finally:
            self._serial.release()

    def _cancel(self, request_id):
        self._event('cancel_attempt', request_id=request_id)
        event, box = threading.Event(), []
        def call():
            try:
                box.append(self.adapter.cancel(request_id))
            except BaseException as error:
                box.append(error)
            finally:
                event.set()
        threading.Thread(target=call, name='research-cancel', daemon=True).start()
        event.wait(min(POST_CANCEL_SECONDS, max(0, (self._watchdog_ns-time.monotonic_ns())/1e9)))
        if not event.is_set():
            self._event('cancel_timeout', request_id=request_id, cessation_proven=False)
            return Result('failed', error='cancel deadline exceeded', uncertain=True)
        value = box[0]
        if isinstance(value, BaseException):
            self._event('cancel_error', request_id=request_id,
                        error=f'{type(value).__name__}: {value}', cessation_proven=False)
            return Result('failed', error=str(value), uncertain=True)
        if not isinstance(value, Result):
            self._event('cancel_invalid_result', request_id=request_id, cessation_proven=False)
            return Result('failed', error='cancel returned non-Result', uncertain=True)
        with self._lock:
            if value.details.get('notification_sent') is True:
                self.timestamps['cancel_sent'] = time.monotonic_ns()
            if value.details.get('protocol_ack') is True:
                self.timestamps['cancel_ack'] = time.monotonic_ns()
        self._event('cancel_result', request_id=request_id, status=value.status,
                    cessation_proven=False)
        return value

    def stop(self):
        with self._lock:
            if self._stopped:
                return Result('passed', value={'already_stopped': True}, uncertain=self._uncertain)
            if self.wire_gate:
                self.wire_gate.stop_intent()
            self._stopped = True
            self.timestamps['stop_received'] = time.monotonic_ns()
            active = self._active
            if active or self._effect_possible:
                self._uncertain = True
            self._event('stop', active_request_id=active.request_id if active else None,
                        uncertain=self._uncertain)
        if active:
            return self._cancel(active.request_id)
        return Result('passed', value={'dispatch_gate_closed': True}, uncertain=self._uncertain,
                      details={'cessation_proven': False})

    def reconcile(self, *, observer, evidence, cessation_condition, observed_at_ns):
        """Record independent reconciliation; Stop remains terminal for this run."""
        with self._lock:
            if not self._uncertain or self._active is not None:
                raise RunnerError('uncertain active work must first drain')
            if observer not in {'protocol-observer', 'manual-target', 'owned-process'}:
                raise RunnerError('independent executor observer required; ledger quiet alone is insufficient')
            if self._post_cancel_observation is None or self._post_cancel_observation['observer'] != observer:
                raise RunnerError('five-second independent post-cancel observation required')
            if self._post_cancel_observation['protocol_double_override']:
                raise RunnerError('short protocol-double observation cannot establish cessation')
            if observed_at_ns < self._post_cancel_observation['end_ns']:
                raise RunnerError('reconciliation predates post-cancel observation')
            if (not isinstance(evidence, dict) or evidence.get('executor_drained') is not True
                    or not evidence.get('source') or not evidence.get('details')
                    or not cessation_condition or observed_at_ns < (self.timestamps['stop_received'] or 0)):
                raise RunnerError('specific post-Stop evidence and condition required')
            self._reconciliation = {'observer': observer, 'evidence': evidence,
                                    'cessation_condition': cessation_condition,
                                    'observed_at_ns': observed_at_ns}
            self.timestamps['cessation_verified'] = observed_at_ns
            self._uncertain = False
            self._event('reconciled', observer=observer, cessation_condition=cessation_condition)

    def observe_after_cancel(self, reader, *, observer='fixture-ledger',
                             seconds=POST_CANCEL_SECONDS, protocol_double=False):
        """Take independent readbacks around a finite post-cancel window.

        A stable readback is only evidence of these observed fixtures. It does not
        itself release uncertainty or establish arbitrary browser cessation.
        """
        if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
            raise ValueError('finite observation duration required')
        if seconds < POST_CANCEL_SECONDS and not protocol_double:
            raise ValueError('post-cancel observation must be at least five seconds')
        with self._lock:
            if not self._stopped or self.timestamps['stop_received'] is None:
                raise RunnerError('Stop must precede post-cancel observation')
        first_ns = time.monotonic_ns()
        if first_ns + int(seconds*1e9) >= self._watchdog_ns:
            raise RunnerError('observation cannot fit within watchdog')
        def bounded_read():
            event, box = threading.Event(), []
            def work():
                try:
                    box.append(reader())
                except BaseException as error:
                    box.append(error)
                finally:
                    event.set()
            thread = threading.Thread(target=work, name='research-independent-observer', daemon=True)
            thread.start()
            if not event.wait(max(0, (self._watchdog_ns-time.monotonic_ns())/1e9)):
                with self._lock:
                    self._uncertain = True
                self._event('observer_timeout', observer=observer,
                            outstanding_reader=thread.is_alive(), cessation_proven=False)
                raise RunnerError('independent observer exceeded watchdog')
            if isinstance(box[0], BaseException):
                self._event('observer_error', observer=observer,
                            error=f'{type(box[0]).__name__}: {box[0]}')
                raise RunnerError('independent observer failed') from box[0]
            return box[0]
        first = bounded_read()
        remaining = seconds - (time.monotonic_ns()-first_ns)/1e9
        if remaining > 0:
            time.sleep(remaining)
        second_ns = time.monotonic_ns()
        second = bounded_read()
        value = {'observer': observer, 'start_ns': first_ns, 'end_ns': second_ns,
                 'first': first, 'second': second, 'protocol_double_override': protocol_double}
        with self._lock:
            self._post_cancel_observation = value
            self._event('post_cancel_observation', observer=observer,
                        start_ns=first_ns, end_ns=second_ns,
                        cessation_proven=False)
        return value

    def close(self):
        self.stop()
        with self._lock:
            active = self._active
            self._closed = True
        if self._attached and active is None:
            event, box = threading.Event(), []
            def detach():
                try:
                    box.append(self.adapter.detach())
                except BaseException as error:
                    box.append(error)
                finally:
                    event.set()
            threading.Thread(target=detach, name='research-detach', daemon=True).start()
            event.wait(min(self.case_seconds, 5))
            self.cleanup.append({'detach_status': getattr(box[0], 'status', 'failed') if box else 'deadline',
                                 'detach_is_cessation_evidence': False})
            if not event.is_set():
                with self._lock:
                    self._uncertain = True
        for transport in self.owned_transports:
            transport.close()
            self.cleanup.extend(getattr(transport, 'cleanup', []))
        self._event('closed', active_at_close=active is not None,
                    cessation_proven=self.timestamps['cessation_verified'] is not None)

    def evidence(self, experiment_id, variant, status, **fields):
        state_event, state_box = threading.Event(), []
        def inspect():
            try:
                value = self.adapter.inspect_state()
                encoded = json.dumps(value, ensure_ascii=False, default=str)
                state_box.append(json.loads(encoded) if len(encoded) <= 100_000 else
                                 {'error': 'adapter state exceeded evidence size limit'})
            except BaseException as error:
                state_box.append({'error': f'{type(error).__name__}: {error}'})
            finally:
                state_event.set()
        threading.Thread(target=inspect, name='research-state-inspection', daemon=True).start()
        state_event.wait(0.5)
        adapter_state = state_box[0] if state_box else {'error': 'adapter state inspection deadline'}
        with self._lock:
            if status == 'passed' and self._uncertain:
                raise RunnerError('uncertain run cannot be reported passed')
            identity = {'candidate_id': self.adapter.candidate_id,
                        'candidate_version': self.adapter.candidate_version,
                        'adapter_contract_version': CONTRACT_VERSION,
                        'run_generation': self.run_generation,
                        'target_generation': self.target.generation}
            if any(k in fields and fields[k] != v for k, v in identity.items()):
                raise RunnerError('runner evidence identity cannot be overridden')
            for key, value in identity.items():
                fields.setdefault(key, value)
            fields.setdefault('evidence_level', 'protocol double')
            fields.setdefault('host_audit', list(self.audit))
            fields.setdefault('wire_audit', list(self.wire_gate.audit) if self.wire_gate else [])
            fields.setdefault('timestamps_monotonic_ns', dict(self.timestamps))
            fields.setdefault('outcome_uncertain', self._uncertain)
            fields.setdefault('owned_process_cleanup', list(self.cleanup))
            fields.setdefault('cessation_condition', self._reconciliation)
            fields.setdefault('post_cancel_observation', self._post_cancel_observation)
            fields.setdefault('adapter_state', adapter_state)
            if self._uncertain:
                fields.setdefault('remaining_target_block',
                    f'{self.target.run_id}/{self.target.generation}/{self.target.target_id}: '
                    'executor outcome unresolved; independent reconciliation required')
            return record(experiment_id, variant, status, **fields)

    def write_evidence(self, path, experiment_id, variant, status, **fields):
        value = self.evidence(experiment_id, variant, status, **fields)
        private_json(path, value)
        return path
