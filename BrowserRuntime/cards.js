// Executed by Chrome DevTools evaluate_script with JSON-encoded data arguments.
// Page text is returned as data; it is never evaluated or treated as instructions.
(config, advance) => {
  const text = (node) => (node?.textContent || '').trim().replace(/\s+/g, ' ');
  const nodes = [...document.querySelectorAll(config.card)];
  let pane = config.scroll ? document.querySelector(config.scroll) : nodes[0]?.parentElement;
  if (!config.scroll) {
    while (pane && !(pane.clientHeight > 50 && pane.scrollHeight > pane.clientHeight + 2 && /auto|scroll/.test(getComputedStyle(pane).overflowY))) pane = pane.parentElement;
  }
  pane ||= document.scrollingElement;
  if (advance === 'start' && pane) pane.scrollTop = 0;
  else if (advance === true && pane) pane.scrollTop += Math.max(50, pane.clientHeight * 0.75);
  let truncated = nodes.length > 500;
  const clip = (value, limit) => { if (value.length > limit) truncated = true; return value.slice(0, limit); };
  const cards = nodes.slice(0, 500).map(node => {
    const link = config.link ? node.querySelector(config.link) : node.querySelector('a[href]');
    const url = link?.href || '';
    const id = config.idAttribute ? node.getAttribute(config.idAttribute) || '' : url;
    return {
      id: clip(id, 2048),
      title: clip(text(config.title ? node.querySelector(config.title) : link), 300),
      company: clip(config.company ? text(node.querySelector(config.company)) : '', 200),
      location: clip(config.location ? text(node.querySelector(config.location)) : '', 200),
      badges: clip(config.badges ? text(node.querySelector(config.badges)) : '', 300),
      url: clip(url, 2048)
    };
  });
  const next = config.next ? document.querySelector(config.next) : null;
  const bottom = !!pane && pane.scrollTop + pane.clientHeight >= pane.scrollHeight - 3;
  return {
    url: location.href, readyState: document.readyState, visibility: document.visibilityState,
    cards, placeholders: nodes.length, truncated, bottom,
    scroll: pane ? {top: pane.scrollTop, height: pane.clientHeight, total: pane.scrollHeight} : null,
    loading: !!(config.loading && document.querySelector(config.loading)),
    empty: !!(config.empty && document.querySelector(config.empty)),
    next: !config.next ? 'unknown' : !next || next.disabled || next.getAttribute('aria-disabled') === 'true' ? 'absent-or-disabled' : 'available'
  };
}
