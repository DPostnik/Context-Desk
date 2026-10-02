"""Launch the pinned Chrome for Testing, then expose only its verified local endpoint.

Chrome outlives MCP reconnects so manual sign-in and user tabs are preserved.
No default profile, WebDriver flags or auto-connect discovery. Explicit cookie
import runs in the native host; this helper never receives cookie values.
"""
import json
import fcntl
import os
from pathlib import Path
import socket
import subprocess
import signal
import threading
import time
import urllib.request
from urllib.parse import urlparse

from install import chrome_app, verify_chrome


class ChromeLaunchError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


def chrome_command(executable, profile, port):
    if not Path(executable).is_absolute() or not Path(profile).is_absolute() or not 1024 <= port <= 65535:
        raise ValueError('invalid_chrome_launch_parameters')
    return [str(executable), '--user-data-dir=' + str(profile),
            '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=' + str(port),
            '--no-first-run', '--no-default-browser-check', 'about:blank']


class ChromeHost:
    def __init__(self, root, language='en', max_browsers=2):
        self.root = Path(root).resolve()
        self.profile = self.root / 'testing-profile'
        self.record = self.root / 'testing-chrome-owner.json'
        self.language = language
        self.max_browsers = max_browsers
        self.child = None
        self.owner = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def error(self, ru, en):
        return ChromeLaunchError(ru if self.language == 'ru' else en)

    @staticmethod
    def process_field(pid, field):
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', field + '='],
                                capture_output=True, text=True, timeout=3)
        return result.stdout.strip() if result.returncode == 0 else None

    def process_gone(self, owner):
        """Only definite exit or the recorded zombie permits a fresh launch."""
        if not isinstance(owner, dict) or type(owner.get('pid')) is not int or owner['pid'] <= 0:
            return False
        if self.child and self.child.pid == owner['pid']:
            # Reap our own exited child; never wait on or signal an adopted PID.
            if self.child.poll() is not None:
                return True
        state = self.process_field(owner['pid'], 'stat')
        if state is None:
            return True
        return (state.startswith('Z') and bool(owner.get('birth'))
                and self.process_field(owner['pid'], 'lstart') == owner['birth'])

    def matches(self, owner):
        if not isinstance(owner, dict):
            return False
        pid, port = owner.get('pid'), owner.get('port')
        if type(pid) is not int or pid <= 0 or type(port) is not int or not 1024 <= port <= 65535:
            return False
        executable = owner.get('executable')
        if executable not in self.executables() or owner.get('profile') != str(self.profile):
            return False
        return (self.process_field(pid, 'lstart') == owner.get('birth')
                and bool(owner.get('birth'))
                and self.process_field(pid, 'command') == ' '.join(chrome_command(executable, self.profile, port)))

    @staticmethod
    def executables():
        return [str(chrome_app() / 'Contents/MacOS/Google Chrome for Testing')]

    @staticmethod
    def owns_listener(pid, port):
        result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid),
                                 '-iTCP:' + str(port), '-sTCP:LISTEN', '-Fn'],
                                capture_output=True, text=True, timeout=3)
        listeners = {line[1:] for line in result.stdout.splitlines() if line.startswith('n')}
        return result.returncode == 0 and listeners == {'127.0.0.1:' + str(port)}

    def endpoint(self, owner):
        if not self.matches(owner) or not self.owns_listener(owner['pid'], owner['port']):
            return None
        base = 'http://127.0.0.1:' + str(owner['port'])
        try:
            with self.opener.open(base + '/json/version', timeout=1) as response:
                value = json.loads(response.read(32768))
            ws = urlparse(value['webSocketDebuggerUrl'])
            if (not value.get('Browser', '').startswith('Chrome/') or ws.scheme != 'ws'
                    or ws.hostname != '127.0.0.1' or ws.port != owner['port']
                    or ws.username or ws.password or ws.query or ws.fragment
                    or not ws.path.startswith('/devtools/browser/')
                    or (owner.get('browserPath') and owner['browserPath'] != ws.path)):
                return None
            # Recheck after the read: no adoption of a replaced PID/listener.
            if not self.matches(owner) or not self.owns_listener(owner['pid'], owner['port']):
                return None
            owner['browserPath'] = ws.path
            return base
        except (OSError, ValueError, KeyError):
            return None

    def persist(self, owner):
        temporary = self.record.with_suffix('.tmp')
        with temporary.open('w') as stream:
            json.dump(owner, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        temporary.replace(self.record)

    def ensure(self, cancelled=None, seconds=15):
        if self.root.parent.name != 'environments':
            return self.ensure_owned(cancelled, seconds)
        # Serialize only admission/startup, never page operations. Existing
        # profiles are not reassigned and live browsers are never evicted.
        with (self.root.parent / 'launch.lock').open('a') as lock:
            deadline = time.monotonic() + seconds
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if (cancelled and cancelled.is_set()) or time.monotonic() >= deadline:
                        raise self.error('Запуск браузера занят. Действие не отправлено.',
                                         'Browser startup is busy. No action was sent.')
                    time.sleep(0.05)
            own = json.loads(self.record.read_text()) if self.record.exists() else None
            if own is None or self.process_gone(own):
                active = 0
                for record in self.root.parent.glob('*/testing-chrome-owner.json'):
                    owner = json.loads(record.read_text())
                    if not self.process_gone(owner):
                        active += 1
                if active >= self.max_browsers:
                    raise self.error('Достигнут лимит браузеров. Заверши неиспользуемый Chrome этого приложения через Cmd+Q или увеличь лимит в настройках. Действие не отправлено.',
                                     'Browser limit reached. Quit an unused Chrome owned by this app with Cmd+Q or increase the limit in settings. No action was sent.')
            return self.ensure_owned(cancelled, seconds)

    def ensure_owned(self, cancelled=None, seconds=15):
        cancelled = cancelled or threading.Event()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.profile.is_symlink():
            raise self.error('Профиль браузера не должен быть символической ссылкой.', 'The browser profile must not be a symbolic link.')
        self.profile.mkdir(exist_ok=True, mode=0o700)
        owner = None
        if self.record.exists():
            old = json.loads(self.record.read_text())
            pid = old.get('pid')
            if type(pid) is not int or pid <= 0:
                raise self.error('Некорректная запись процесса Chrome.', 'Invalid Chrome process record.')
            if not self.process_gone(old):
                if not self.matches(old):
                    raise self.error('Процесс Chrome изменился. Подключение отклонено.', 'The Chrome process changed. Connection was denied.')
                owner = old
        if owner is None:
            if cancelled.is_set():
                raise self.error('Запуск браузера отменён.', 'Browser startup was cancelled.')
            executable = next((p for p in self.executables() if os.access(p, os.X_OK)), None)
            if not executable:
                raise self.error('Установи Chrome for Testing по инструкции в настройках браузера.',
                                 'Install Chrome for Testing using the browser settings instructions.')
            verify_chrome(chrome_app())
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            # A positive port uses Chrome's documented manual debugging mode.
            # Listener ownership below handles a port allocation race fail-closed.
            env = {k: v for k, v in os.environ.items() if k in ('HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL')}
            self.child = subprocess.Popen(chrome_command(executable, self.profile, port),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=env, start_new_session=True)
            owner = {'pid': self.child.pid, 'port': port, 'executable': executable,
                     'profile': str(self.profile), 'birth': self.process_field(self.child.pid, 'lstart')}
            self.persist(owner)
        self.owner = owner
        end = time.monotonic() + seconds
        while time.monotonic() < end and not cancelled.is_set():
            if self.child and self.child.poll() is not None:
                raise self.error('Chrome не запустился. Закрой старое окно браузера Context Desk и попробуй снова.',
                                 'Chrome did not start. Close the previous Context Desk browser and try again.')
            endpoint = self.endpoint(owner)
            if endpoint:
                self.persist(owner)
                return endpoint
            cancelled.wait(0.2)
        raise self.error('Подключение к Chrome не подтверждено. Автоматического перезапуска не было.',
                         'Chrome connection was not confirmed. No automatic restart was attempted.')

    def close_created_for_test(self):
        """Only fixtures call this; never terminate a reattached/user Chrome."""
        if not self.child or self.child.poll() is not None:
            return
        if not self.owner or not self.matches(self.owner):
            raise RuntimeError('refuse_to_terminate_unverified_chrome')
        self.child.terminate()
        self.child.wait(timeout=10)

    def control(self, close=False):
        """Explicit native UI control. Never launches Chrome or retries a signal."""
        if not self.record.exists():
            return {'running': False}
        if not close:
            return self.control_owned(False)
        with (self.root / 'operation.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise self.error('Браузер выполняет операцию. Действие управления не отправлено.',
                                 'The browser is performing an operation. No control action was sent.')
            return self.control_owned(close)

    def prepare_cookie_import(self):
        """Caller holds operation.lock throughout preparation, write and verification.

        Never attach to a live browser for import: it could overwrite refreshed
        cookies in an active tab. A persisted uncertain write is retired only
        after definite exit of the recorded Chrome, as in the executor.
        """
        old = json.loads(self.record.read_text()) if self.record.exists() else None
        if old is not None and not self.process_gone(old):
            return {'code': 'destination_running'}
        fence = self.root / 'executor-in-flight.json'
        if fence.exists():
            if old is None or not self.process_gone(old):
                return {'code': 'uncertain'}
            fence.unlink()
        endpoint = self.ensure()
        return {'webSocketURL': endpoint.replace('http://', 'ws://', 1) + self.owner['browserPath']}

    def control_owned(self, close):
        owner = json.loads(self.record.read_text())
        if self.process_gone(owner):
            return {'running': False}
        if not self.endpoint(owner):
            raise self.error('Принадлежность Chrome не подтверждена. Действие не выполнено.',
                             'Chrome ownership could not be verified. No action was performed.')
        if not close:
            return {'running': True, 'pid': owner['pid']}
        if (self.root / 'executor-in-flight.json').exists():
            raise self.error('В браузере есть незавершённая операция. Проверь её результат и закрой Chrome вручную.',
                             'The browser has an unfinished operation. Review its result and quit Chrome manually.')
        intent = self.root / 'manual-close.json'
        if intent.exists() and json.loads(intent.read_text()) == owner:
            raise self.error('Закрытие уже запрошено. Автоматического повтора нет; проверь окно Chrome.',
                             'Close was already requested. It will not be retried; check the Chrome window.')
        # Persist intent before sending. A crashed helper cannot resend the signal.
        with intent.open('w') as stream:
            json.dump(owner, stream)
            stream.flush()
            os.fsync(stream.fileno())
        if not self.matches(owner):
            raise self.error('Процесс Chrome изменился. Закрытие отклонено.',
                             'The Chrome process changed. Close was denied.')
        os.kill(owner['pid'], signal.SIGTERM)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.process_gone(owner):
                return {'running': False}
            time.sleep(.1)
        raise self.error('Завершение Chrome не подтверждено. Команда закрытия не повторена.',
                         'Chrome exit was not confirmed. The close command was not repeated.')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--language', choices=('ru', 'en'), default='en')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--close', action='store_true')
    mode.add_argument('--prepare-cookie-import', action='store_true')
    parser.add_argument('--max-browsers', type=int, choices=range(1, 9), default=2)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        host = ChromeHost(args.root, args.language, args.max_browsers)
        print(json.dumps(host.prepare_cookie_import() if args.prepare_cookie_import else host.control(args.close)))
    except Exception as error:
        print(json.dumps({'error': str(error)}))
        raise SystemExit(1)
