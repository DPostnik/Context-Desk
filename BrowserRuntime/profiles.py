"""Native profile lease enforcement. Storage contains metadata, never site tokens.

Caller holds the environment operation.lock across validation AND dispatch.
The native catalog writer uses that same lock and atomic file replacement.
"""
import json
from pathlib import Path
import uuid


def validate(root, lease, workspace=None, allow_human=False, language='en'):
    from server import Rejected
    message = ('Управление профилем изменилось или недоступно. Выбери профиль в меню браузера. Действие не отправлено.'
               if language == 'ru' else
               'Profile control changed or is unavailable. Select a profile in the Browser menu. No action was sent.')
    root = Path(root).resolve()
    catalog = root.parent.parent / 'profiles.json' if root.parent.name == 'environments' else root / 'profiles.json'
    try:
        if catalog.is_symlink():
            raise ValueError()
        if not catalog.exists():
            if lease is not None or (catalog.parent / 'profiles-required').exists():
                raise ValueError()
            return  # Unmigrated legacy environments only.
        if catalog.stat().st_size > 8 * 1024 * 1024:
            raise ValueError()
        value = json.loads(catalog.read_text())
        if value.get('schema') != 1 or not isinstance(value.get('profiles'), dict):
            raise ValueError()
        profile = value['profiles'].get(root.name.lower())
        if profile is None:
            if lease is not None:
                raise ValueError()
            return
        if (str(uuid.UUID(profile['id'])) != root.name.lower()
                or lease is None or str(uuid.UUID(profile['generation'])) != str(uuid.UUID(lease))
                or profile['state'] not in (('active', 'human') if allow_human else ('active',))
                or not isinstance(profile.get('owner'), str) or not profile['owner']):
            raise ValueError()
        if workspace is not None and str(Path(workspace).resolve()) != profile['project']:
            raise ValueError()
    except (ValueError, TypeError, KeyError, OSError):
        raise Rejected(message) from None


def idle(host):
    """Called under operation.lock. No close, launch, retry or fence retirement."""
    from server import Rejected
    if host.record.exists():
        owner = json.loads(host.record.read_text())
        if not host.process_gone(owner):
            raise Rejected('Сначала закрой Chrome этого профиля.' if host.language == 'ru' else 'Close this profile’s Chrome first.')
    elif (host.root / 'executor-in-flight.json').exists():
        raise Rejected('Исход операции неизвестен.' if host.language == 'ru' else 'The operation outcome is unknown.')
