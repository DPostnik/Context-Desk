import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest

import cdp
import page_input
import server
from server import Browser, Rejected, dispatch

# Smallest JPEG header carrying a 640x400 start-of-frame marker.
JPEG = b'\xff\xd8\xff\xe0\x00\x04\x00\x00\xff\xc0\x00\x0b\x08\x01\x90\x02\x80\x01\x01\x11\x00\xff\xd9'


class FakePage:
    def __init__(self, url='https://example.test/', fail_on=None):
        self.url, self.fail_on = url, fail_on
        self.sent = []
        self.closed = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.closed += 1

    def send(self, method, params=None, seconds=None):
        self.sent.append((method, params))
        if method == self.fail_on:
            raise cdp.CDPTransportError('cdp_connection_lost_outcome_may_be_unknown')
        if method == 'Runtime.evaluate':
            if params['expression'] == 'devicePixelRatio':
                return {'result': {'value': 2}}
            return {'result': {'value': {'url': self.url, 'title': 'Fixture', 'readyState': 'complete'}}}
        if method == 'Page.getLayoutMetrics':
            return {'cssVisualViewport': {'clientWidth': 1280, 'clientHeight': 800, 'pageX': 0, 'pageY': 40}}
        if method == 'Page.captureScreenshot':
            return {'data': base64.b64encode(JPEG).decode()}
        return {}


class HelperTests(unittest.TestCase):
    def test_capture_scale_bounds_longer_side(self):
        self.assertEqual(page_input.capture_scale(1280, 800, 2), 0.5)
        self.assertEqual(page_input.capture_scale(600, 400, 1), 1.0)
        self.assertAlmostEqual(page_input.capture_scale(800, 3000, 1) * 3000, 1280)

    def test_coordinates_map_back_and_reject_outside(self):
        viewport = {'imageWidth': 640, 'imageHeight': 400, 'cssWidth': 1280, 'cssHeight': 800}
        self.assertEqual(page_input.to_css((320, 100), viewport), (640, 200))
        self.assertIsNone(page_input.to_css((641, 10), viewport))
        self.assertIsNone(page_input.to_css((True, 10), viewport))
        self.assertIsNone(page_input.to_css((None, 10), viewport))

    def test_key_combos(self):
        down, up = page_input.key_events('Enter')
        self.assertEqual((down['type'], down['text'], down['windowsVirtualKeyCode']), ('keyDown', '\r', 13))
        self.assertEqual(up['type'], 'keyUp')
        down, _ = page_input.key_events('cmd+a')
        self.assertEqual((down['type'], down['modifiers'], down['commands']), ('rawKeyDown', 4, ['selectAll']))
        self.assertNotIn('text', down)
        down, _ = page_input.key_events('shift+Tab')
        self.assertEqual((down['key'], down['modifiers']), ('Tab', 8))
        self.assertEqual(page_input.key_events('shift+a')[0]['text'], 'A')
        self.assertEqual(page_input.key_events('+')[0]['key'], '+')
        for invalid in ('', 'hyper+a', 'cmd+cmd+a', 'F13', 'Ä', 'x' * 41):
            self.assertIsNone(page_input.key_events(invalid), invalid)

    def test_mouse_sequences(self):
        click = page_input.mouse_events('click', (5, 6))
        self.assertEqual([e['type'] for e in click], ['mouseMoved', 'mousePressed', 'mouseReleased'])
        double = page_input.mouse_events('double_click', (5, 6))
        self.assertEqual([e.get('clickCount') for e in double if e['type'] == 'mousePressed'], [1, 2])
        self.assertEqual(page_input.mouse_events('right_click', (1, 1))[1]['button'], 'right')
        drag = page_input.mouse_events('drag', (0, 0), (80, 40))
        self.assertEqual((drag[1]['type'], drag[-1]['type'], drag[-1]['x'], drag[-1]['y']), ('mousePressed', 'mouseReleased', 80, 40))
        wheel = page_input.mouse_events('scroll', (3, 4), delta=(0, 600))[-1]
        self.assertEqual((wheel['type'], wheel['deltaY']), ('mouseWheel', 600))

    def test_jpeg_size(self):
        self.assertEqual(cdp.jpeg_size(JPEG), (640, 400))
        self.assertIsNone(cdp.jpeg_size(b'\x89PNG'))


class BrowserInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.browser = Browser(Path(self.directory.name), rpc=lambda *_: {'content': []})
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.browser.page_session_factory = lambda: self.page
        self.browser.stopped.wait = lambda seconds: False

    def tearDown(self):
        self.directory.cleanup()

    def inputs(self):
        return [p for m, p in self.page.sent if m.startswith('Input.')]

    def test_screenshot_returns_image_and_mapping(self):
        result = self.browser.screenshot('owner')
        capture = next(p for m, p in self.page.sent if m == 'Page.captureScreenshot')
        self.assertEqual(capture['clip'], {'x': 0, 'y': 40, 'width': 1280, 'height': 800, 'scale': 0.5})
        self.assertEqual((result['width'], result['height'], result['url']), (640, 400, 'https://example.test/'))
        blocks = server.content(result)
        self.assertEqual([b['type'] for b in blocks], ['text', 'image'])
        self.assertNotIn('_image', json.loads(blocks[0]['text']))
        with self.assertRaises(Rejected):
            self.browser.screenshot('other')

    def test_click_maps_screenshot_pixels_and_journals_once(self):
        with self.assertRaises(Rejected):  # Coordinates need a screenshot first.
            self.browser.input('owner', 'click', expected_url='https://example.test/', x=10, y=10)
        self.assertEqual(self.inputs(), [])
        self.browser.screenshot('owner')
        result = self.browser.input('owner', 'click', 'click-000001', 'https://example.test/', x=320, y=100)
        pressed = [p for p in self.inputs() if p['type'] == 'mousePressed']
        self.assertEqual([(p['x'], p['y']) for p in pressed], [(640, 200)])
        self.assertEqual(result['actionID'], 'click-000001')
        record = json.loads((Path(self.directory.name) / 'records/action-click-000001.json').read_text())
        self.assertEqual(record['state'], 'dispatched_observe_result')
        before = len(self.page.sent)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', 'click-000001', 'https://example.test/', x=320, y=100)
        self.assertFalse([m for m, _ in self.page.sent[before:] if m.startswith('Input.')])

    def test_guarded_actions_need_matching_page(self):
        self.browser.screenshot('owner')
        for action in ('click', 'key', 'type', 'drag'):
            with self.assertRaises(Rejected):
                self.browser.input('owner', action, x=1, y=1, key='Enter', text='x', to_x=2, to_y=2)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', expected_url='https://other.test/', x=1, y=1)
        self.assertEqual(self.inputs(), [])
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', expected_url='https://example.test/', x=641, y=1)

    def test_scroll_and_hover_do_not_need_url_and_scroll_invalidates_mapping(self):
        self.browser.screenshot('owner')
        self.browser.input('owner', 'hover', x=10, y=10)
        self.browser.input('owner', 'scroll', delta_y=500)
        wheel = [p for p in self.inputs() if p['type'] == 'mouseWheel'][0]
        self.assertEqual((wheel['x'], wheel['y'], wheel['deltaY']), (640, 400, 500))
        self.assertIsNone(self.browser.viewport)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'scroll', delta_y=0)

    def test_key_and_type(self):
        self.browser.input('owner', 'key', expected_url='https://example.test/', key='cmd+a')
        self.browser.input('owner', 'type', expected_url='https://example.test/', text='hello')
        self.assertEqual(self.page.sent[-2], ('Input.insertText', {'text': 'hello'}))
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'key', expected_url='https://example.test/', key='nope+x')

    def test_lost_dispatch_stops_without_replay(self):
        self.browser.screenshot('owner')
        self.page.fail_on = 'Input.dispatchMouseEvent'
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'click', 'click-000002', 'https://example.test/', x=1, y=1)
        self.assertIn('no_replay', str(raised.exception))
        self.assertTrue(self.browser.failed)
        record = json.loads((Path(self.directory.name) / 'records/action-click-000002.json').read_text())
        self.assertEqual(record['state'], 'outcome_unknown')
        self.assertEqual(len([m for m, _ in self.page.sent if m.startswith('Input.')]), 1)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'hover', x=1, y=1)

    def test_wait_and_screenshot_flag(self):
        result = self.browser.input('owner', 'wait', seconds=1, screenshot=True)
        self.assertEqual(result['width'], 640)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'wait', seconds=30)

    def test_dispatch_schema(self):
        names = [t['name'] for t in server.catalog()]
        self.assertIn('browser_screenshot', names)
        self.assertIn('browser_input', names)
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'browser_input', {'session': 'owner', 'action': 'click', 'selector': '#x'})
        self.assertEqual(dispatch(self.browser, 'browser_screenshot', {'session': 'owner'})['height'], 400)


class WebSocketTests(unittest.TestCase):
    def serve(self, replies):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        received = []

        def run():
            connection, _ = listener.accept()
            data = b''
            while b'\r\n\r\n' not in data:
                data += connection.recv(4096)
            key = [l.split(': ')[1] for l in data.decode().split('\r\n') if l.lower().startswith('sec-websocket-key')][0]
            accept = base64.b64encode(hashlib.sha1((key + cdp.GUID).encode()).digest()).decode()
            connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
            state = {'buffer': b''}

            def text_frame():
                while True:
                    while len(state['buffer']) < 2:
                        state['buffer'] += connection.recv(65536)
                    buffer = state['buffer']
                    length, offset = buffer[1] & 0x7F, 2
                    if length == 126:
                        length, offset = struct.unpack('!H', buffer[2:4])[0], 4
                    while len(state['buffer']) < offset + 4 + length:
                        state['buffer'] += connection.recv(65536)
                    buffer = state['buffer']
                    mask = buffer[offset:offset + 4]
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(buffer[offset + 4:offset + 4 + length]))
                    state['buffer'] = buffer[offset + 4 + length:]
                    if buffer[0] & 0x0F == 0x1:  # Skip pongs and other control frames.
                        return payload

            for reply in replies:
                received.append(json.loads(text_frame()))
                for chunk in reply(received[-1]):
                    connection.sendall(chunk)
            connection.close()
        threading.Thread(target=run, daemon=True).start()
        return listener.getsockname()[1], received

    @staticmethod
    def server_frame(payload, opcode=0x1, final=True):
        size = len(payload)
        head = bytes(((0x80 if final else 0) | opcode,))
        head += bytes((size,)) if size < 126 else bytes((126,)) + struct.pack('!H', size) if size < 65536 else bytes((127,)) + struct.pack('!Q', size)
        return head + payload

    def test_reply_after_events_ping_and_fragments(self):
        big = 'x' * 70000

        def reply(message):
            body = json.dumps({'id': message['id'], 'result': {'value': big}}).encode()
            return [self.server_frame(b'{"method":"Page.loadEventFired","params":{}}'),
                    self.server_frame(b'hi', 0x9),
                    self.server_frame(body[:100], 0x1, False), self.server_frame(body[100:], 0x0)]
        port, received = self.serve([reply, lambda m: [self.server_frame(json.dumps({'id': m['id'], 'error': {'message': 'No node'}}).encode())]])
        with cdp.PageSession(port, 'A' * 32, timeout=5) as page:
            self.assertEqual(page.send('Runtime.evaluate', {'expression': '1'})['value'], big)
            self.assertEqual(page.events[0]['method'], 'Page.loadEventFired')
            with self.assertRaises(cdp.CDPError):
                page.send('DOM.focus')
        self.assertEqual([m['method'] for m in received], ['Runtime.evaluate', 'DOM.focus'])

    def test_closed_connection_is_unknown_outcome(self):
        port, _ = self.serve([lambda m: []])
        with cdp.PageSession(port, 'B' * 32, timeout=5) as page:
            with self.assertRaises(cdp.CDPTransportError):
                page.send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': 1, 'y': 1})

    def test_rejects_unverified_target(self):
        with self.assertRaises(cdp.CDPTransportError):
            cdp.PageSession(9222, '../browser/x')


if __name__ == '__main__':
    unittest.main()
