"""Pure helpers for screenshots and trusted input: sizing, coordinate mapping, key events."""
import re

MAX_IMAGE_SIDE = 1280
QUALITY = 70
ACTIONS = ('click', 'double_click', 'right_click', 'hover', 'drag', 'scroll', 'scroll_to', 'key', 'type', 'select', 'upload', 'dialog', 'wait')
# Consequence classes that require the observed expectedURL and explicit confirmation.
RISKY = frozenset(('submit', 'navigation', 'dialog', 'upload'))
MAX_FILES = 10
MAX_FRAMES = 50
MAX_FRAME_DEPTH = 3
MAX_FRAME_REFS = 20000
MAX_SCRIPT = 20000
EVAL_CHARS = 20000
LOG_CHARS = 20000
MAX_UPLOAD_BYTES = 200 * 1024 * 1024
# Settling: network/DOM quiet period, and requests treated as long-lived (polling, streams).
QUIET = 0.3
LONG_REQUEST = 2.0
DIFF_SOURCE_CHARS = 60000
# Seconds a page may take to run a trivial script before it counts as blocked.
RESPONSIVE = 3
DIFF_CHARS = 4000
REF = re.compile(r'\[(ref_\d+)\]')
POINTER = frozenset(('click', 'double_click', 'right_click', 'hover', 'drag'))
MAX_TEXT = 5000

MODIFIERS = {'alt': 1, 'option': 1, 'ctrl': 2, 'control': 2, 'cmd': 4, 'command': 4, 'meta': 4, 'shift': 8}
NAMED = {
    'enter': ('Enter', 'Enter', 13, '\r'), 'return': ('Enter', 'Enter', 13, '\r'),
    'tab': ('Tab', 'Tab', 9, None), 'escape': ('Escape', 'Escape', 27, None), 'esc': ('Escape', 'Escape', 27, None),
    'backspace': ('Backspace', 'Backspace', 8, None), 'delete': ('Delete', 'Delete', 46, None),
    'space': (' ', 'Space', 32, ' '),
    'arrowup': ('ArrowUp', 'ArrowUp', 38, None), 'up': ('ArrowUp', 'ArrowUp', 38, None),
    'arrowdown': ('ArrowDown', 'ArrowDown', 40, None), 'down': ('ArrowDown', 'ArrowDown', 40, None),
    'arrowleft': ('ArrowLeft', 'ArrowLeft', 37, None), 'left': ('ArrowLeft', 'ArrowLeft', 37, None),
    'arrowright': ('ArrowRight', 'ArrowRight', 39, None), 'right': ('ArrowRight', 'ArrowRight', 39, None),
    'home': ('Home', 'Home', 36, None), 'end': ('End', 'End', 35, None),
    'pageup': ('PageUp', 'PageUp', 33, None), 'pagedown': ('PageDown', 'PageDown', 34, None),
}
# macOS editing shortcuts are browser commands, not text; CDP needs them named.
COMMANDS = {('a', 4): 'selectAll', ('c', 4): 'copy', ('x', 4): 'cut', ('v', 4): 'paste',
            ('z', 4): 'undo', ('z', 12): 'redo'}


def capture_scale(css_width, css_height, device_ratio):
    """CDP clip scale keeping the image's longer side within MAX_IMAGE_SIDE pixels."""
    longest = max(css_width, css_height) * device_ratio
    return min(1.0, MAX_IMAGE_SIDE / longest) if longest > 0 else 1.0


def to_css(point, viewport):
    """Map screenshot pixel coordinates to viewport CSS pixels; None when outside the image."""
    x, y = point
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (x, y)):
        return None
    if not (0 <= x <= viewport['imageWidth'] and 0 <= y <= viewport['imageHeight']):
        return None
    return (x * viewport['cssWidth'] / viewport['imageWidth'],
            y * viewport['cssHeight'] / viewport['imageHeight'])


def key_events(combo):
    """CDP keyDown/keyUp parameters for a combo such as "Enter", "shift+Tab" or "cmd+a"."""
    if not isinstance(combo, str) or not 0 < len(combo) <= 40:
        return None
    parts = [p for p in re.split(r'\+(?!$)', combo.strip()) if p]
    if not parts:
        return None
    *names, main = parts
    modifiers = 0
    for name in names:
        bit = MODIFIERS.get(name.lower())
        if bit is None or modifiers & bit:
            return None
        modifiers |= bit
    named = NAMED.get(main.lower())
    if named:
        key, code, virtual, text = named
    elif len(main) == 1 and main.isascii() and main.isprintable():
        key = main
        if main.isalpha():
            code, virtual = 'Key' + main.upper(), ord(main.upper())
            if modifiers & 8:
                key = main.upper()
        elif main.isdigit():
            code, virtual = 'Digit' + main, ord(main)
        else:
            code, virtual = '', 0
        text = key
    else:
        return None
    if modifiers & 6:
        text = None  # Ctrl/Cmd combos are shortcuts, never typed characters.
    down = {'type': 'keyDown' if text else 'rawKeyDown', 'key': key, 'code': code,
            'windowsVirtualKeyCode': virtual, 'nativeVirtualKeyCode': virtual, 'modifiers': modifiers}
    if text:
        down.update(text=text, unmodifiedText=text)
    command = COMMANDS.get((main.lower(), modifiers))
    if command:
        down['commands'] = [command]
    up = {'type': 'keyUp', 'key': key, 'code': code, 'windowsVirtualKeyCode': virtual,
          'nativeVirtualKeyCode': virtual, 'modifiers': modifiers}
    return [down, up]


def mouse_events(action, start, end=None, delta=(0, 0)):
    """Ordered Input.dispatchMouseEvent parameters in CSS pixels."""
    x, y = start
    move = {'type': 'mouseMoved', 'x': x, 'y': y, 'button': 'none', 'buttons': 0}
    if action == 'hover':
        return [move]
    if action == 'scroll':
        return [move, {'type': 'mouseWheel', 'x': x, 'y': y, 'deltaX': delta[0], 'deltaY': delta[1]}]
    button, held = ('right', 2) if action == 'right_click' else ('left', 1)

    def press(count, px=x, py=y):
        return [{'type': 'mousePressed', 'x': px, 'y': py, 'button': button, 'buttons': held, 'clickCount': count},
                {'type': 'mouseReleased', 'x': px, 'y': py, 'button': button, 'buttons': 0, 'clickCount': count}]
    if action in ('click', 'right_click'):
        return [move] + press(1)
    if action == 'double_click':
        return [move] + press(1) + press(2)
    if action == 'drag':
        ex, ey = end
        steps = [{'type': 'mouseMoved', 'x': x + (ex - x) * i / 8, 'y': y + (ey - y) * i / 8,
                  'button': 'left', 'buttons': 1} for i in range(1, 9)]
        return [move, {'type': 'mousePressed', 'x': x, 'y': y, 'button': 'left', 'buttons': 1, 'clickCount': 1}] + steps + [
            {'type': 'mouseReleased', 'x': ex, 'y': ey, 'button': 'left', 'buttons': 0, 'clickCount': 1}]
    raise ValueError(action)


def dialog_info(params):
    return {'type': str(params.get('type', ''))[:20], 'message': str(params.get('message', ''))[:500],
            'url': str(params.get('url', ''))[:8192], **({'defaultPrompt': str(params['defaultPrompt'])[:200]} if params.get('defaultPrompt') else {})}


def tree_changes(before, after, url, limit=DIFF_CHARS):
    """Compact change list between two interactive trees, keyed by stable refs.

    A new document (fresh registry or other URL path) has no comparable refs, so the
    head of the new tree is returned instead of a diff.
    """
    head_url, now_url = before.get('url', '').split('#')[0], url.split('#')[0]
    if after.get('fresh') or head_url != now_url:
        tree = after.get('tree', '')
        return {'kind': 'new_page', 'tree': tree[:limit], 'truncated': len(tree) > limit or bool(after.get('truncated'))}

    def lines(tree):
        found = {}
        for line in tree.split('\n'):
            match = REF.search(line)
            if match:
                found[match.group(1)] = line.strip()[2:] if line.strip().startswith('- ') else line.strip()
        return found
    old, new = lines(before.get('tree', '')), lines(after.get('tree', ''))

    def same(ref):  # Focus moves with every click; it is not a page change.
        return old[ref].replace(' focused', '') == new[ref].replace(' focused', '')
    entries = ([('+ ', new[r]) for r in new if r not in old] + [('~ ', new[r]) for r in new if r in old and not same(r)] +
               [('- ', old[r]) for r in old if r not in new])
    text, shown = [], 0
    for sign, line in entries:
        if shown + len(line) + 3 > limit:
            break
        text.append(sign + line)
        shown += len(line) + 3
    result = {'kind': 'same_page', 'added': sum(r not in old for r in new), 'changed': sum(r in old and not same(r) for r in new),
              'removed': sum(r not in new for r in old), 'diff': '\n'.join(text)}
    if len(text) < len(entries):
        result['truncated'] = True
    if before.get('truncated') or after.get('truncated'):
        result['partial'] = True  # Large page: elements past the read limit are not compared.
    return result


ROLE_WORDS = {
    'button': ('button', 'btn', 'кнопка', 'кнопку', 'кнопки'),
    'link': ('link', 'ссылка', 'ссылку', 'ссылки'),
    'textbox': ('field', 'input', 'textbox', 'box', 'поле', 'ввод', 'ввода'),
    'searchbox': ('search', 'поиск', 'поиска'),
    'checkbox': ('checkbox', 'check', 'галочка', 'флажок', 'чекбокс'),
    'radio': ('radio', 'option', 'переключатель'),
    'combobox': ('select', 'dropdown', 'combobox', 'список', 'выпадающий'),
    'heading': ('heading', 'title', 'header', 'заголовок'),
    'image': ('image', 'picture', 'photo', 'картинка', 'изображение', 'фото'),
    'tab': ('tab', 'вкладка'),
    'menuitem': ('menu', 'меню'),
    'iframe': ('frame', 'iframe', 'фрейм'),
}
STOP_WORDS = frozenset(('the', 'a', 'an', 'to', 'of', 'for', 'on', 'in', 'with', 'and', 'or', 'that', 'which',
                        'и', 'в', 'во', 'на', 'для', 'с', 'со', 'по', 'к', 'из', 'или', 'который', 'которая'))
FIND_LIMIT = 20
FIND_SOURCE_CHARS = 100000
# Role words that are also common content words count less than explicit type words.
WEAK_ROLE_WORDS = frozenset(('search', 'поиск', 'поиска', 'title', 'header', 'option', 'select', 'menu', 'меню', 'check', 'box', 'input', 'frame'))


def _norm(text):
    return text.lower().replace('ё', 'е')


def _stem(word):
    # Crude ru/en stemming: the first five letters carry the root for most inflections.
    return word[:5] if len(word) >= 5 else word


def find_matches(tree, query, limit=FIND_LIMIT):
    """Tree lines ranked by lexical match with a description (roles, names, values, hrefs; ru/en)."""
    tokens = [t for t in re.findall(r'\w+', _norm(query)) if t not in STOP_WORDS]
    if not tokens:
        return []
    role_tokens = {t for t in tokens if any(t in words for words in ROLE_WORDS.values())}
    plain = [t for t in tokens if t not in role_tokens or t in WEAK_ROLE_WORDS]
    ranked = []
    for order, line in enumerate(tree.split('\n')):
        ref = REF.search(line)
        if not ref:
            continue
        body = line.strip()[2:] if line.strip().startswith('- ') else line.strip()
        role = body.split(' ', 1)[0]
        words = re.findall(r'\w+', _norm(body.split(' ', 1)[1] if ' ' in body else ''))
        stems = {_stem(w) for w in words}
        score, plain_hits = 0.0, 0
        for token in tokens:
            hit = 1.0 if token in words else 0.6 if _stem(token) in stems else 0.0
            score += hit
            if hit and token in plain:
                plain_hits += 1
        role_words = [t for t in role_tokens if t in ROLE_WORDS.get(role, ())]
        role_hit = bool(role_words)
        if role_hit:
            score += max(0.7 if t in WEAK_ROLE_WORDS else 1.5 for t in role_words)
        # Content words must match; a description made only of role words must match the role.
        if (plain and not plain_hits) or (not plain and not role_hit):
            continue
        ranked.append((-score / len(tokens), order, ref.group(1), body[:300]))
    ranked.sort()
    return [{'ref': ref, 'line': body, 'score': round(-score, 2)} for score, _, ref, body in ranked[:limit]]
