"""Pure helpers for screenshots and trusted input: sizing, coordinate mapping, key events."""
import re

MAX_IMAGE_SIDE = 1280
QUALITY = 70
ACTIONS = ('click', 'double_click', 'right_click', 'hover', 'drag', 'scroll', 'scroll_to', 'key', 'type', 'select', 'wait')
# Actions that can submit, edit or navigate need the page the model saw.
GUARDED = frozenset(('click', 'double_click', 'right_click', 'drag', 'key', 'type', 'select'))
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
