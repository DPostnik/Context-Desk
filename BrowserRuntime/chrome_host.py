"""Launch a dedicated normal Chrome, then expose only its verified local endpoint.

Chrome outlives MCP reconnects so manual sign-in and user tabs are preserved.
No default profile, credential copying, WebDriver flags or auto-connect discovery.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.request
from urllib.parse import urlparse


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
    def __init__(self, root, language='en'):
        self.root = Path(root).resolve()
        self.profile = self.root / 'profile'
        self.record = self.root / 'chrome-owner.json'
        self.language = language
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
        return [str(base / 'Google Chrome.app/Contents/MacOS/Google Chrome')
                for base in (Path('/Applications'), Path.home() / 'Applications')]

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
            if self.process_field(pid, 'command') is not None:
                if not self.matches(old):
                    raise self.error('Процесс Chrome изменился. Подключение отклонено.', 'The Chrome process changed. Connection was denied.')
                owner = old
        if owner is None:
            if cancelled.is_set():
                raise self.error('Запуск браузера отменён.', 'Browser startup was cancelled.')
            executable = next((p for p in self.executables() if os.access(p, os.X_OK)), None)
            if not executable:
                raise self.error('Установи Google Chrome в папку Applications.', 'Install Google Chrome in Applications.')
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
