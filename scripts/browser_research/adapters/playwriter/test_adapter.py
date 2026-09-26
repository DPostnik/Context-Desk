"""C03 offline protocol doubles; no relay, browser, extension, or model call."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from adapters.playwriter import PlaywriterAdapter
from contract import Request, Target
from evidence import ROOT


def result(identity, *, value=None, action=False, error=False):
    lines = ['Console output:', '[log] __CDR_ID__' + json.dumps(identity, separators=(',', ':'))]
    if action:
        lines.append('[log] __CDR_VALUE__' + json.dumps(value, separators=(',', ':')))
    response = {'content': [{'type': 'text', 'text': '\n'.join(lines) + '\n'}]}
    if error:
        response['isError'] = True
    return response


class Double:
    def __init__(self, identity):
        self.identity = dict(identity)
        self.calls = []
        self.guard_started = threading.Event()
        self.guard_continue = threading.Event()
        self.action_started = threading.Event()
        self.action_continue = threading.Event()
        self.hold_guard = False
        self.hold_action = False
        self.transport_loss = False
        self.malformed_attach = False

    def __call__(self, method, params, rpc_id, deadline_ns):
        self.calls.append((method, params, rpc_id, deadline_ns))
        action = not rpc_id.endswith((':attach', ':guard'))
        if action:
            self.action_started.set()
            if self.hold_action:
                self.action_continue.wait(2)
        else:
            self.guard_started.set()
            if self.hold_guard:
                self.guard_continue.wait(2)
        if self.transport_loss:
            raise ConnectionError('simulated owned MCP child lost')
        if self.malformed_attach and rpc_id.endswith(':attach'):
            return {'content': [{'type': 'text', 'text': 'malformed identity output'}]}
        return result(self.identity, value={'controlled': True}, action=action)


class PlaywriterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        cls.check_root = Path(tempfile.mkdtemp(prefix='playwriter-checks-', dir=ROOT))
        os.chmod(cls.check_root, 0o700)
        cls.target = Target('run-1', 'gen-1', 'http://127.0.0.1:34982/run-1/A',
                            'nonce-1', 'selected-profile', 'A1b2C3d4')
        cls.identity = {'run_id': 'run-1', 'generation': 'gen-1', 'target': 'A',
                        'url': cls.target.url, 'nonce': 'nonce-1',
                        'stored_nonce': 'nonce-1', 'target_id': 'A1b2C3d4'}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.check_root)

    def setUp(self):
        self.driver = Double(self.identity)
        self.adapter = self.make_adapter()
        static = self.adapter.preflight()
        self.assertEqual(static.status, 'passed', static.error)

    def make_adapter(self, **overrides):
        options = dict(browser_consent=True, current_profile='selected-profile',
                       runtime_binding_verified=True, dependency_lock_verified=True,
                       current_extension_verified=True, selected_tabs_verified=True,
                       relay_ownership_verified=True, explicit_relay_host=True,
                       auto_enable_disabled=True, direct_cdp_disabled=True,
                       allowed_upload_roots=(self.check_root,),
                       allowed_download_roots=(self.check_root,))
        options.update(overrides)
        return PlaywriterAdapter(self.driver, **options)

    def req(self, op, args=None, target=None, id='r1'):
        return Request(id, target or self.target, op, args or {}, time.monotonic_ns() + 5_000_000_000)

    def attach(self):
        value = self.adapter.attach(self.req('attach'))
        self.assertEqual(value.status, 'passed', value.error)
        return value

    def test_e00_source_preflight_is_read_only_and_runtime_prerequisites_block(self):
        self.assertEqual(self.adapter.preflight().value['files'], 498)
        self.assertEqual(self.driver.calls, [])
        blocked = self.make_adapter(dependency_lock_verified=False)
        blocked.preflight()
        self.assertEqual(blocked.attach(self.req('attach')).status, 'blocked')
        denied = self.make_adapter(browser_consent=False)
        denied.preflight()
        self.assertEqual(denied.attach(self.req('attach')).status, 'blocked')
        wrong_route = self.make_adapter(direct_cdp_disabled=False)
        wrong_route.preflight()
        self.assertEqual(wrong_route.attach(self.req('attach')).status, 'blocked')
        self.assertEqual(self.driver.calls, [])

    def test_e01_e02_exact_target_nonce_decoy_and_no_fallback(self):
        self.driver.identity['target_id'] = 'decoy-id'
        self.assertEqual(self.adapter.attach(self.req('attach')).status, 'blocked')
        self.assertIsNone(self.adapter.inspect_state()['attached_target'])
        self.driver.identity = dict(self.identity)
        self.attach()
        code = self.driver.calls[-1][1]['arguments']['code']
        self.assertIn('Target.getTargetInfo', code)
        self.assertIn('getCDPSession({page:__cdPage})', code)
        self.assertIn('context.pages().filter', code)
        self.assertNotIn('resetPlaywright', code)
        wrong = Target(self.target.run_id, self.target.generation, self.target.url,
                       self.target.nonce, self.target.profile, 'another-id')
        calls = len(self.driver.calls)
        self.assertEqual(self.adapter.execute(self.req('click', {'selector': '#x'}, wrong)).status, 'blocked')
        self.assertEqual(len(self.driver.calls), calls)
        self.driver.identity['nonce'] = 'stale-nonce'
        self.assertEqual(self.adapter.execute(self.req('click', {'selector': '#x'})).status, 'blocked')
        self.assertEqual(self.driver.calls[-1][2], 'r1:guard')

    def test_e01_malformed_attach_response_latches_uncertainty(self):
        self.driver.malformed_attach = True
        response = self.adapter.attach(self.req('attach'))
        self.assertEqual(response.status, 'failed')
        self.assertTrue(response.uncertain)
        self.assertTrue(self.adapter.inspect_state()['uncertain'])
        calls = len(self.driver.calls)
        self.assertEqual(self.adapter.attach(self.req('attach')).status, 'blocked')
        self.assertEqual(len(self.driver.calls), calls)

    def test_e03_e06_mapped_operations_and_private_paths(self):
        self.attach()
        pdf = self.check_root / 'synthetic.pdf'
        pdf.write_bytes(b'%PDF-synthetic')
        cases = [('observe', {}), ('click', {'selector': '#next'}),
                 ('fill', {'selector': '#name', 'value': 'synthetic'}),
                 ('evaluate', {'function': '() => document.title'}),
                 ('wait', {'text': 'Ready'}),
                 ('upload', {'selector': '#file', 'filePaths': [str(pdf)]}),
                 ('download', {'selector': '#output', 'saveAs': str(self.check_root / 'output.mp3')})]
        for index, (operation, args) in enumerate(cases):
            response = self.adapter.execute(self.req(operation, args, id=f'op-{index}'))
            self.assertEqual(response.status, 'passed', (operation, response.error))
            self.assertEqual(self.driver.calls[-2][2], f'op-{index}:guard')
            self.assertEqual(self.driver.calls[-1][2], f'op-{index}')
            self.assertEqual(self.driver.calls[-1][1]['name'], 'execute')
            self.assertIn('Target.getTargetInfo', self.driver.calls[-1][1]['arguments']['code'])
        calls = len(self.driver.calls)
        self.assertEqual(self.adapter.execute(self.req('upload', {'selector': '#file', 'filePaths': ['/etc/hosts']})).status, 'blocked')
        self.assertEqual(self.adapter.execute(self.req('download', {'selector': '#output', 'saveAs': '/tmp/output.mp3'})).status, 'blocked')
        self.assertEqual(self.adapter.execute(self.req('evaluate', {'code': 'return 1'})).status, 'blocked')
        self.assertEqual(self.adapter.execute(self.req('reset')).status, 'not applicable')
        self.assertEqual(len(self.driver.calls), calls)

    def test_e07_stop_during_guard_withholds_action(self):
        self.attach()
        self.driver.guard_started.clear()
        self.driver.hold_guard = True
        answers = []
        worker = threading.Thread(target=lambda: answers.append(self.adapter.execute(
            self.req('click', {'selector': '#x'}, id='stop-guard'))))
        worker.start()
        self.assertTrue(self.driver.guard_started.wait(2))
        cancellation = self.adapter.cancel('stop-guard')
        self.assertEqual(cancellation.status, 'not applicable')
        self.assertFalse(cancellation.uncertain)
        self.driver.guard_continue.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(answers[0].status, 'blocked')
        self.assertEqual(self.driver.calls[-1][2], 'stop-guard:guard')
        self.assertEqual(self.adapter.execute(self.req('observe')).status, 'blocked')

    def test_e07_e08_late_action_timeout_cannot_clear_uncertainty(self):
        self.attach()
        notifications = []
        self.adapter._notify = lambda method, params: notifications.append((method, params))
        self.driver.hold_action = True
        answers = []
        worker = threading.Thread(target=lambda: answers.append(self.adapter.execute(
            self.req('evaluate', {'function': '() => 1', 'timeout': 250}, id='stop-action'))))
        worker.start()
        self.assertTrue(self.driver.action_started.wait(2))
        cancellation = self.adapter.cancel('stop-action')
        self.assertTrue(cancellation.uncertain)
        self.assertTrue(cancellation.details['notification_sent'])
        self.assertEqual(notifications[0][1]['requestId'], 'stop-action')
        self.driver.action_continue.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(answers[0].status, 'failed')
        self.assertTrue(answers[0].uncertain)
        self.assertEqual(self.adapter.detach().status, 'blocked')
        self.assertLessEqual(self.driver.calls[-1][1]['arguments']['timeout'], 250)

    def test_evaluate_generated_script_invokes_function_in_page_context(self):
        # Execute the actual generated JavaScript with a minimal Node VM double.
        # Host and page use distinct globals; no browser, relay, or package code runs.
        cases = [("() => 2", None),
                 ("arg => arg.answer * 2", {'answer': 21}),
                 ("async arg => ({text: arg.text, count: await Promise.resolve(3)})",
                  {'text': 'Привет "world"\n雪'}),
                 ("() => { globalThis.hostMarker = 99; return typeof process }", None)]
        scripts = []
        for index, (function, arg) in enumerate(cases):
            request = self.req('evaluate', {'function': function, 'arg': arg}, id=f'node-{index}')
            scripts.append(self.adapter._guard_code(self.target) + self.adapter._action_code(request))
        node_script = r'''
const vm = require('node:vm');
const fs = require('node:fs');
const scripts = JSON.parse(fs.readFileSync(0, 'utf8'));
const pageWorld = vm.createContext({
  window: {CONFIG: {run:'run-1', generation:'gen-1', target:'A'}, fixtureSessionNonce:'nonce-1'},
  sessionStorage: {getItem: () => 'nonce-1'}
});
const page = {
  isClosed: () => false,
  url: () => 'http://127.0.0.1:34982/run-1/A',
  async evaluate(expression, arg) {
    const isFunction = typeof expression === 'function';
    const source = isFunction ? expression.toString() : expression;
    const value = vm.runInContext('(' + source + ')', pageWorld);
    // Playwright invokes function arguments, but evaluates strings as expressions.
    // A string whose result is a function must not be implicitly invoked here.
    return isFunction ? await value(arg) : value;
  }
};
const context = {pages: () => [page]};
const getCDPSession = async () => ({send: async () => ({targetInfo:{targetId:'A1b2C3d4'}})});
(async () => {
  const values = [];
  for (const code of scripts) {
    const logs = [];
    const hostWorld = vm.createContext({context, getCDPSession, console:{log: x => logs.push(x)}});
    await vm.runInContext('(async () => {' + code + '})()', hostWorld, {timeout:1000});
    const marker = logs.find(x => x.startsWith('__CDR_VALUE__'));
    if (!marker) throw Error('generated action did not return a value');
    values.push({value: JSON.parse(marker.slice('__CDR_VALUE__'.length)), hostMarker:hostWorld.hostMarker ?? null});
  }
  process.stdout.write(JSON.stringify({values, pageMarker:pageWorld.hostMarker ?? null}));
})().catch(e => { process.stderr.write(String(e)); process.exitCode = 1; });
'''
        completed = subprocess.run(['node', '-e', node_script], input=json.dumps(scripts),
                                   text=True, capture_output=True, timeout=5, check=True)
        observed = json.loads(completed.stdout)
        self.assertEqual([entry['value'] for entry in observed['values']],
                         [2, 42, {'text': 'Привет "world"\n雪', 'count': 3}, 'undefined'])
        self.assertEqual([entry['hostMarker'] for entry in observed['values']], [None] * len(cases))
        self.assertEqual(observed['pageMarker'], 99)

    def test_e09_transport_loss_and_owned_transport_only(self):
        self.attach()
        self.driver.transport_loss = True
        response = self.adapter.execute(self.req('click', {'selector': '#x'}))
        self.assertEqual(response.status, 'failed')
        self.assertTrue(response.uncertain)
        self.assertEqual(self.adapter.detach().status, 'blocked')
        self.driver.transport_loss = False
        closed = []
        other = self.make_adapter(close_owned_transport=lambda: closed.append('owned MCP child'))
        other.preflight()
        self.assertEqual(other.attach(self.req('attach')).status, 'passed')
        self.assertEqual(other.detach().status, 'passed')
        self.assertEqual(closed, ['owned MCP child'])


if __name__ == '__main__':
    unittest.main()
