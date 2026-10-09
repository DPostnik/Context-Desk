"""Minimal CDP client for one owned page target over the verified loopback endpoint.

Scope is deliberately narrow: one WebSocket attached only to the page target
recorded when the task opened its tab. A persistent session stays open across
tool calls, so page events (dialogs) that arrive between calls are buffered and
can be answered. Commands are never resent; a lost reply surfaces as an error,
drops the connection, and the caller treats the outcome as unknown.
"""
import base64
import hashlib
import json
import os
import re
import select
import socket
import struct
import time

MAX_MESSAGE = 24_000_000
TARGET = re.compile(r'[0-9A-F]{32}')
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class CDPError(RuntimeError):
    """A determinate protocol error reported by Chrome for one command."""


class CDPTransportError(RuntimeError):
    """The connection failed; the command outcome may be unknown."""


def frame(payload, opcode=0x1):
    """One masked, unfragmented client frame (RFC 6455 section 5.2)."""
    header = bytes((0x80 | opcode,))
    size = len(payload)
    if size < 126:
        header += bytes((0x80 | size,))
    elif size < 1 << 16:
        header += bytes((0x80 | 126,)) + struct.pack('!H', size)
    else:
        header += bytes((0x80 | 127,)) + struct.pack('!Q', size)
    mask = os.urandom(4)
    return header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


class PageSession:
    def __init__(self, port, target, timeout=20, persistent=False):
        if not isinstance(port, int) or not 0 < port < 65536 or not isinstance(target, str) or not TARGET.fullmatch(target):
            raise CDPTransportError('owned_page_target_unverified')
        self.port, self.target, self.timeout = port, target, timeout
        self.socket = None
        self.buffer = b''
        self.counter = 0
        self.events = []
        self.persistent = persistent  # close() keeps it open; shutdown() ends it.
        self.page_enabled = False

    def __enter__(self):
        if self.socket is None:
            self.connect()
        return self

    def __exit__(self, *_):
        self.close()

    def connect(self):
        key = base64.b64encode(os.urandom(16)).decode('ascii')
        path = '/devtools/page/' + self.target
        try:
            self.socket = socket.create_connection(('127.0.0.1', self.port), timeout=self.timeout)
            self.socket.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:' + str(self.port) +
                                 '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key +
                                 '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode('ascii'))
            header = b''
            while b'\r\n\r\n' not in header:
                chunk = self.socket.recv(4096)
                if not chunk or len(header) > 16_384:
                    raise CDPTransportError('cdp_handshake_failed')
                header += chunk
        except OSError as error:
            self.close()
            raise CDPTransportError('cdp_connect_failed: ' + type(error).__name__)
        head, self.buffer = header.split(b'\r\n\r\n', 1)
        lines = head.decode('latin-1').split('\r\n')
        fields = dict((k.strip().lower(), v.strip()) for k, v in (line.split(':', 1) for line in lines[1:] if ':' in line))
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode('ascii')).digest()).decode('ascii')
        if not lines[0].startswith('HTTP/1.1 101') or fields.get('sec-websocket-accept') != accept:
            self.close()
            raise CDPTransportError('cdp_handshake_rejected')

    def close(self):
        if not self.persistent:
            self.shutdown()

    def shutdown(self):
        if self.socket is not None:
            try:
                self.socket.sendall(frame(b'', 0x8))
            except OSError:
                pass
            self.socket.close()
            self.socket = None
        self.buffer = b''
        self.page_enabled = False

    def _exact(self, count, deadline):
        while len(self.buffer) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CDPTransportError('cdp_deadline_outcome_may_be_unknown')
            self.socket.settimeout(min(remaining, 1.0))
            try:
                chunk = self.socket.recv(max(65536, count - len(self.buffer)))
            except socket.timeout:
                continue
            except OSError:
                raise CDPTransportError('cdp_connection_lost_outcome_may_be_unknown')
            if not chunk:
                raise CDPTransportError('cdp_connection_closed_outcome_may_be_unknown')
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _message(self, deadline):
        parts, size = [], 0
        while True:
            first, second = self._exact(2, deadline)
            opcode, length = first & 0x0F, second & 0x7F
            if second & 0x80:
                raise CDPTransportError('cdp_masked_server_frame')
            if length == 126:
                length = struct.unpack('!H', self._exact(2, deadline))[0]
            elif length == 127:
                length = struct.unpack('!Q', self._exact(8, deadline))[0]
            if size + length > MAX_MESSAGE:
                raise CDPTransportError('cdp_message_too_large')
            payload = self._exact(length, deadline)
            if opcode == 0x8:
                raise CDPTransportError('cdp_connection_closed_outcome_may_be_unknown')
            if opcode == 0x9:
                self.socket.sendall(frame(payload, 0xA))
                continue
            if opcode == 0xA:
                continue
            parts.append(payload)
            size += length
            if first & 0x80:
                return b''.join(parts)

    def poll(self, timeout):
        """Next event within timeout, or None. A started frame is always read whole."""
        try:
            return self._poll(timeout)
        except CDPTransportError:
            self.shutdown()  # Frame sync or pending replies are unknown now.
            raise

    def _poll(self, timeout):
        if self.socket is None:
            raise CDPTransportError('cdp_not_connected')
        if not self.buffer:
            ready, _, _ = select.select([self.socket], [], [], max(0.0, timeout))
            if not ready:
                return None
        try:
            message = json.loads(self._message(time.monotonic() + max(timeout, self.timeout)))
        except ValueError:
            raise CDPTransportError('cdp_invalid_message')
        if isinstance(message, dict) and 'method' in message:
            return message
        return None

    def send(self, method, params=None, seconds=None, interrupt=None, session=None):
        try:
            return self._send(method, params, seconds, interrupt, session)
        except CDPTransportError:
            self.shutdown()  # A late reply could otherwise be mistaken for a new one.
            raise

    def _send(self, method, params=None, seconds=None, interrupt=None, session=None):
        """Send one command once and wait for its reply; events are kept in order.

        With interrupt, an event of that name ends the wait early and returns
        {'interrupted': event}: input that opens a JavaScript dialog is answered by
        Chrome only after the dialog closes. The late reply is ignored by id.
        session addresses a flattened child target (a cross-origin iframe).
        """
        if self.socket is None:
            raise CDPTransportError('cdp_not_connected')
        self.counter += 1
        identifier = self.counter
        message = {'id': identifier, 'method': method, 'params': params or {}}
        if session is not None:
            message['sessionId'] = session
        data = json.dumps(message, separators=(',', ':')).encode()
        try:
            self.socket.sendall(frame(data))
        except OSError:
            raise CDPTransportError('cdp_send_failed_outcome_may_be_unknown')
        deadline = time.monotonic() + (seconds or self.timeout)
        while True:
            try:
                message = json.loads(self._message(deadline))
            except ValueError:
                raise CDPTransportError('cdp_invalid_message')
            if not isinstance(message, dict):
                raise CDPTransportError('cdp_invalid_message')
            if message.get('id') == identifier:
                if 'error' in message:
                    detail = message['error'].get('message', 'error') if isinstance(message['error'], dict) else 'error'
                    raise CDPError(str(detail)[:500])
                return message.get('result', {})
            if 'method' in message and len(self.events) < 1000:
                self.events.append(message)
            if interrupt is not None and message.get('method') == interrupt:
                return {'interrupted': message}


def jpeg_size(data):
    """Pixel width and height from a JPEG start-of-frame marker, or None."""
    if data[:2] != b'\xff\xd8':
        return None
    index = 2
    while index + 9 < len(data):
        if data[index] != 0xFF:
            return None
        marker = data[index + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            index += 2
            continue
        length = struct.unpack('!H', data[index + 2:index + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height, width = struct.unpack('!HH', data[index + 5:index + 9])
            return width, height
        index += 2 + length
    return None
