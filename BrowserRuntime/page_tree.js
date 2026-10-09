// Page model for the agent: an accessibility-style tree with stable element refs,
// main-content text, and ref resolution for trusted input. Read-only except for
// the ref registry and, on request, scrolling an element into view or setting a
// <select> value. Page content is untrusted data.
(request) => {
  const KEY = Symbol.for('context-desk.refs');
  const registry = window[KEY] || (window[KEY] = {next: 1, byRef: new Map(), byElement: new WeakMap()});
  const clip = (value, max) => {
    const text = String(value ?? '').slice(0, max * 4).replace(/\s+/g, ' ').trim();
    return (text.length > max ? text.slice(0, max - 1) + '…' : text).toWellFormed();
  };
  const refOf = (element) => {
    let ref = registry.byElement.get(element);
    if (!ref) {
      ref = 'ref_' + registry.next++;
      registry.byElement.set(element, ref);
      registry.byRef.set(ref, new WeakRef(element));
    }
    return ref;
  };
  const lookup = (ref) => {
    const element = typeof ref === 'string' ? registry.byRef.get(ref)?.deref() : null;
    return element && element.isConnected ? element : null;
  };
  const sensitive = (element) => {
    const type = (element.getAttribute('type') || '').toLowerCase();
    const autocomplete = (element.getAttribute('autocomplete') || '').toLowerCase();
    return type === 'password' || type === 'hidden' ||
      ['current-password', 'new-password', 'one-time-code', 'cc-number', 'cc-csc', 'cc-exp', 'cc-exp-month', 'cc-exp-year']
        .some((token) => autocomplete.includes(token));
  };
  const implicit = {A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', SUMMARY: 'button',
    H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading', IMG: 'image',
    NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', ASIDE: 'complementary', FORM: 'form',
    DIALOG: 'dialog', TABLE: 'table', TR: 'row', TH: 'columnheader', TD: 'cell', UL: 'list', OL: 'list', LI: 'listitem',
    LABEL: 'label', IFRAME: 'iframe', FRAME: 'iframe', VIDEO: 'video', AUDIO: 'audio', OPTION: 'option', P: 'paragraph'};
  const roleOf = (element) => {
    const explicit = (element.getAttribute('role') || '').trim().split(/\s+/)[0];
    if (explicit) return explicit;
    if (element.tagName === 'INPUT') {
      const type = (element.getAttribute('type') || 'text').toLowerCase();
      return {button: 'button', submit: 'button', reset: 'button', image: 'button', checkbox: 'checkbox', radio: 'radio',
        range: 'slider', file: 'button', search: 'searchbox', email: 'textbox', number: 'spinbutton'}[type] || 'textbox';
    }
    if (element.tagName === 'A' && !element.hasAttribute('href')) return 'generic';
    if (element.isContentEditable && element.getAttribute('contenteditable') !== null) return 'textbox';
    return implicit[element.tagName] || 'generic';
  };
  const INTERACTIVE = new Set(['link', 'button', 'checkbox', 'radio', 'textbox', 'searchbox', 'combobox', 'slider',
    'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem', 'listbox']);
  const STRUCTURE = new Set(['heading', 'image', 'navigation', 'main', 'banner', 'contentinfo', 'complementary', 'form',
    'dialog', 'alertdialog', 'alert', 'table', 'row', 'columnheader', 'cell', 'list', 'listitem', 'iframe', 'video',
    'audio', 'region', 'article', 'tablist', 'menu', 'menubar', 'tabpanel', 'paragraph', 'label', 'status']);
  const interactive = (element, role) => INTERACTIVE.has(role) ||
    (element.tabIndex >= 0 && element.hasAttribute('tabindex')) || element.hasAttribute('onclick');
  const ownText = (element) => {
    let text = '';
    for (const child of element.childNodes) if (child.nodeType === Node.TEXT_NODE) text += child.nodeValue + ' ';
    return text;
  };
  const nameOf = (element, role) => {
    const labelled = element.getAttribute('aria-labelledby');
    if (labelled) {
      const text = labelled.split(/\s+/).map((id) => element.ownerDocument.getElementById(id)?.textContent || '').join(' ');
      if (text.trim()) return clip(text, 120);
    }
    for (const attribute of ['aria-label', 'alt', 'title']) {
      const value = element.getAttribute(attribute);
      if (value && value.trim()) return clip(value, 120);
    }
    if (['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName)) {
      const label = element.labels?.[0]?.textContent || element.getAttribute('placeholder') ||
        (['submit', 'button', 'reset'].includes(element.type) ? element.value : '');
      return clip(label, 120);
    }
    if (INTERACTIVE.has(role) || ['heading', 'label', 'cell', 'columnheader', 'option', 'paragraph', 'listitem', 'status', 'alert'].includes(role)) {
      return clip(element.innerText ?? element.textContent, role === 'paragraph' || role === 'listitem' || role === 'cell' ? 300 : 150);
    }
    return '';
  };
  const hidden = (element) => {
    if (element.hidden || element.getAttribute('aria-hidden') === 'true') return true;
    const style = getComputedStyle(element);
    return style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse';
  };
  const frameOffset = (element) => {
    let x = 0, y = 0, view = element.ownerDocument.defaultView;
    while (view && view !== window && view.frameElement) {
      const frame = view.frameElement, rect = frame.getBoundingClientRect(), style = getComputedStyle(frame);
      x += rect.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
      y += rect.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop);
      view = frame.ownerDocument.defaultView;
    }
    return {x, y};
  };

  if (request.op === 'resolve' || request.op === 'select') {
    const element = lookup(request.ref);
    if (!element) return {error: 'stale_ref'};
    if (request.op === 'select') {
      if (element.tagName !== 'SELECT') return {error: 'ref_is_not_select'};
      if (element.disabled) return {error: 'element_disabled'};
      const wanted = String(request.value);
      const option = [...element.options].find((o) => o.label.trim() === wanted || o.value === wanted);
      if (!option) return {error: 'option_not_found', options: [...element.options].slice(0, 50).map((o) => clip(o.label, 80))};
      element.value = option.value;
      element.dispatchEvent(new Event('input', {bubbles: true}));
      element.dispatchEvent(new Event('change', {bubbles: true}));
      return {selected: clip(option.label, 80)};
    }
    let rect = element.getBoundingClientRect();
    let offset = frameOffset(element);
    const inside = () => rect.width > 0 && rect.height > 0 && offset.y + rect.top >= 0 && offset.x + rect.left >= 0 &&
      offset.y + rect.bottom <= innerHeight && offset.x + rect.right <= innerWidth;
    let scrolled = false;
    if (!inside()) {
      element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      scrolled = true;
      rect = element.getBoundingClientRect();
      offset = frameOffset(element);
    }
    if (rect.width <= 0 || rect.height <= 0) return {error: 'element_not_visible', scrolled};
    const local = {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2};
    const hit = element.ownerDocument.elementFromPoint(local.x, local.y);
    const covered = hit && hit !== element && !element.contains(hit) && !(hit.control === element) &&
      !(hit.tagName === 'LABEL' && hit.contains(element)) && !(hit.shadowRoot && hit.contains(element)) &&
      !(element.getRootNode() instanceof ShadowRoot && hit === element.getRootNode().host);
    if (request.focus) element.focus({preventScroll: true});
    return {x: offset.x + local.x, y: offset.y + local.y, scrolled, disabled: !!element.disabled,
      obscuredBy: covered ? clip(roleOf(hit) + ' "' + (nameOf(hit, roleOf(hit)) || clip(hit.textContent, 60)) + '"', 120) : null};
  }

  const started = performance.now();
  const limits = {characters: request.maxChars, nodes: 40000, milliseconds: 2500, depth: request.depth};
  const result = {kind: request.mode === 'text' ? 'page_text' : 'page_tree', url: location.href.slice(0, 8192).toWellFormed(),
    title: clip(document.title, 300), readyState: document.readyState, truncated: false, reason: null};

  if (request.mode === 'text') {
    const root = request.ref ? lookup(request.ref) :
      document.querySelector('main, [role="main"], article') || document.body;
    if (!root) return {...result, error: request.ref ? 'stale_ref' : 'no_body'};
    const text = (root.innerText || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    result.source = request.ref ? 'ref' : (root === document.body ? 'body' : root.tagName.toLowerCase());
    result.totalChars = text.length;
    result.text = text.slice(0, limits.characters).toWellFormed();
    if (text.length > limits.characters) { result.truncated = true; result.reason = 'character_limit'; }
    return result;
  }

  const lines = [];
  let characters = 0, visited = 0, refs = 0, stop = null;
  const emit = (indent, text) => {
    const line = '  '.repeat(indent) + '- ' + text;
    if (characters + line.length + 1 > limits.characters) { stop = 'character_limit'; return false; }
    lines.push(line); characters += line.length + 1;
    return true;
  };
  const describe = (element, role) => {
    const name = nameOf(element, role);
    let text = role + (name ? ' "' + name.replace(/"/g, "'") + '"' : '') + ' [' + refOf(element) + ']';
    refs++;
    if (role === 'heading') text += ' level=' + (element.tagName.match(/^H(\d)$/)?.[1] || element.getAttribute('aria-level') || '');
    if (element.tagName === 'A' && element.href && !element.href.startsWith('javascript:')) text += ' href=' + clip(element.href, 200);
    if (['INPUT', 'TEXTAREA'].includes(element.tagName) && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file'].includes(element.type)) {
      text += ' value="' + (sensitive(element) ? (element.value ? '[redacted]' : '') : clip(element.value, 120).replace(/"/g, "'")) + '"';
    }
    if (element.tagName === 'SELECT') text += ' value="' + clip(element.selectedOptions[0]?.label, 80).replace(/"/g, "'") + '"';
    if (element.isContentEditable && role === 'textbox' && element.tagName !== 'INPUT' && element.tagName !== 'TEXTAREA') {
      text += ' value="' + clip(element.innerText, 120).replace(/"/g, "'") + '"';
    }
    if ('checked' in element && ['checkbox', 'radio'].includes(element.type)) text += element.checked ? ' checked' : ' unchecked';
    const pressed = element.getAttribute('aria-checked') || element.getAttribute('aria-pressed');
    if (pressed) text += ' checked=' + pressed;
    if (element.getAttribute('aria-expanded')) text += ' expanded=' + element.getAttribute('aria-expanded');
    if (element.getAttribute('aria-selected') === 'true') text += ' selected';
    if (element.disabled || element.getAttribute('aria-disabled') === 'true') text += ' disabled';
    if (element === element.ownerDocument.activeElement && element !== element.ownerDocument.body) text += ' focused';
    return text;
  };
  const walk = (node, depth, indent) => {
    if (stop) return;
    if (++visited > limits.nodes) { stop = 'node_limit'; return; }
    if ((visited & 255) === 0 && performance.now() - started > limits.milliseconds) { stop = 'time_limit'; return; }
    if (depth > limits.depth) { result.depthLimited = true; return; }
    if (node.nodeType === Node.TEXT_NODE) {
      if (request.filter === 'all' && node.parentElement && roleOf(node.parentElement) === 'generic') {
        const text = clip(node.nodeValue, 300);
        if (text.length > 1) emit(indent, 'text "' + text.replace(/"/g, "'") + '"');
      }
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) for (const child of node.childNodes) walk(child, depth + 1, indent);
      return;
    }
    const element = node;
    if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK'].includes(element.tagName)) return;
    if (element.tagName === 'INPUT' && element.type === 'hidden') return;
    if (hidden(element)) return;
    const role = roleOf(element);
    const isInteractive = interactive(element, role);
    let next = indent;
    const show = isInteractive || (request.filter === 'all' && (STRUCTURE.has(role) && (role !== 'image' || nameOf(element, role))));
    if (show) {
      if (!emit(indent, describe(element, role))) return;
      next = indent + 1;
    }
    if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
      let inner = null;
      try { inner = element.contentDocument; } catch (_) {}
      if (inner?.body) walk(inner.body, depth + 1, next);
      else if (show) lines[lines.length - 1] += ' (cross-origin: use browser_screenshot)';
      return;
    }
    // Interactive leaves already carry their text as the name.
    if (isInteractive && ['link', 'button', 'option', 'menuitem', 'tab'].includes(role) && !element.querySelector('input,select,textarea,button,a[href]')) return;
    if (show && ['heading', 'paragraph', 'listitem', 'cell', 'columnheader', 'label'].includes(role) &&
        !element.querySelector('input,select,textarea,button,a[href],[role],[tabindex],[onclick]')) return;
    if (element.shadowRoot) walk(element.shadowRoot, depth + 1, next);
    for (const child of element.childNodes) {
      walk(child, depth + 1, next);
      if (stop) return;
    }
  };
  const root = request.ref ? lookup(request.ref) : document.body;
  if (!root) return {...result, error: request.ref ? 'stale_ref' : 'no_body'};
  walk(root, 0, 0);
  if (stop) { result.truncated = true; result.reason = stop; }
  result.refs = refs;
  result.tree = lines.join('\n').toWellFormed();
  result.scroll = {y: Math.round(scrollY), height: document.documentElement.scrollHeight, viewport: innerHeight};
  return result;
}
