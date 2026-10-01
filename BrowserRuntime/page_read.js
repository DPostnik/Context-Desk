// Bounded, read-only DOM inspection. No full accessibility tree or frame traversal.
// Never invent action UIDs: only the explicit interactive snapshot supplies them.
(selector) => {
  const limits = {nodes: 4000, characters: 24000, controls: 100, milliseconds: 100};
  const started = performance.now();
  const result = {kind: 'page_read', url: location.href.slice(0, 8192).toWellFormed(), title: document.title.slice(0, 500).toWellFormed(),
    readyState: document.readyState, scope: 'bounded_dom', selector: selector || null,
    complete: false, interactiveUIDs: false, truncated: false, reason: 'bounded_read',
    visitedNodes: 0, omittedFrames: 0, openShadowRoots: 0,
    omitted: ['iframe_contents', 'closed_shadow_roots', 'form_values', 'accessibility_tree'],
    text: '', controls: [], limits};
  let root;
  try { root = selector ? document.querySelector(selector) : document.body; }
  catch (_) { return {...result, error: 'invalid_selector'}; }
  result.found = !!root;
  if (!root) return result;
  const stack = [root];
  const chunks = [];
  let characters = 0;
  const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'SVG', 'CANVAS', 'TEXTAREA']);
  const clip = (value, max = 160) => String(value || '').slice(0, max + 1).replace(/\s+/g, ' ').trim().slice(0, max).toWellFormed();
  while (stack.length) {
    if (result.visitedNodes >= limits.nodes || performance.now() - started >= limits.milliseconds) {
      result.truncated = true;
      result.reason = result.visitedNodes >= limits.nodes ? 'node_limit' : 'time_limit';
      break;
    }
    const node = stack.pop();
    result.visitedNodes++;
    // Only descend into the selected subtree. Keep the stack bounded by depth,
    // rather than materializing all children of a potentially huge element.
    if (node !== root && node.nextSibling) stack.push(node.nextSibling);
    if (node.nodeType === Node.TEXT_NODE) {
      const raw = node.nodeValue || '';
      const remaining = limits.characters - characters;
      // Slice before normalizing: a giant text node must not defeat the bound.
      const text = clip(raw.slice(0, remaining + 1), remaining);
      if (text) { chunks.push(text); characters += text.length + 1; }
      if (raw.length > remaining || characters >= limits.characters) {
        result.truncated = true; result.reason = 'character_limit'; break;
      }
      continue;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) continue;
    if (skip.has(node.tagName) || node.hidden || node.getAttribute('aria-hidden') === 'true') continue;
    const style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') continue;
    if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') { result.omittedFrames++; continue; }
    const role = node.getAttribute('role');
    if (['A', 'BUTTON', 'INPUT', 'SELECT', 'SUMMARY'].includes(node.tagName) || role) {
      if (result.controls.length < limits.controls) {
        const control = {tag: node.tagName.toLowerCase(), role: clip(role),
          label: clip(node.getAttribute('aria-label') || node.getAttribute('title') ||
                      (node.firstChild?.nodeType === Node.TEXT_NODE ? node.firstChild.nodeValue : '')),
          disabled: !!node.disabled};
        if (node.tagName === 'A' && node.hasAttribute('href')) {
          try { const url = new URL(node.getAttribute('href'), location.href);
            if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password)
              control.url = url.href.slice(0, 2048).toWellFormed();
          } catch (_) {}
        }
        result.controls.push(control);
      } else { result.truncated = true; result.reason = 'control_limit'; }
    }
    if (node.firstChild) stack.push(node.firstChild);
    if (node.shadowRoot?.firstChild) { result.openShadowRoots++; stack.push(node.shadowRoot.firstChild); }
  }
  result.text = chunks.join('\n').slice(0, limits.characters).toWellFormed();
  return result;
}
