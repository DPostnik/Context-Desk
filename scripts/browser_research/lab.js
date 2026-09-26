/* Synthetic fixture content, not Context Desk product UI. */
'use strict';
const C = window.CONFIG;
const $ = id => document.getElementById(id);
const report = error => { $('error').textContent = String(error); };
async function api(path, data) {
  const response = await fetch(C.base + path, data === undefined ? {} : {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(data)
  });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error);
  return value;
}
// Exposed only as a page-event sink, never as an oracle approval/reset control.
window.fixtureEvent = (kind, detail = {}) => api('event', {
  target: C.target, generation: C.generation, top_level: !C.frame, kind, detail
}).catch(report);
function button(id, handler) {
  $(id).onclick = async event => { try { await handler(event); } catch (error) { report(error); } };
}
$('identity').textContent = `${C.run} / ${C.target} / ${C.generation}`;
const nonceKey = `research-${C.run}-${C.target}`;
if (!sessionStorage.getItem(nonceKey)) sessionStorage.setItem(nonceKey, crypto.randomUUID());
window.fixtureSessionNonce = sessionStorage.getItem(nonceKey);
window.fixtureEvent('loaded', {nonce: window.fixtureSessionNonce});
for (const kind of ['input', 'change', 'blur', 'click']) {
  document.addEventListener(kind, event => {
    if (event.target.id) window.fixtureEvent(kind, {id: event.target.id, value: event.target.value ?? null});
  }, true);
}
let page = 0, descending = false, query = '', lazyPage = 0;
function renderRows(container, rows, table) {
  for (const row of rows) {
    const node = document.createElement(table ? 'tr' : 'p');
    node.dataset.recordId = String(row.id);
    if (table) {
      for (const value of [row.id, row.title, row.city]) {
        const cell = document.createElement('td'); cell.textContent = value; node.append(cell);
      }
    } else node.textContent = `${row.id}: ${row.title} — ${row.city}`;
    container.append(node);
  }
}
async function search() {
  const result = await api(`search?page=${page}&sort=${descending ? 'desc' : 'asc'}&q=${encodeURIComponent(query)}`);
  $('rows').replaceChildren(); renderRows($('rows'), result.rows, true);
  $('coverage').textContent = JSON.stringify({page: result.page, total: result.total, exhausted: result.exhausted});
}
button('filter', async () => { query = $('query').value; page = 0; await search(); });
button('sort', async () => { descending = !descending; await search(); });
button('previous', async () => { page = Math.max(0, page - 1); await search(); });
button('next', async () => { page++; await search(); });
button('noop', () => window.fixtureEvent('noop-next'));
let lazyBusy = false;
async function lazy() {
  if (lazyBusy || lazyPage >= 4) return;
  lazyBusy = true;
  try { const result = await api(`search?page=${lazyPage}`); renderRows($('lazy'), result.rows, false); lazyPage++; }
  finally { lazyBusy = false; }
}
$('lazy').onscroll = () => { if ($('lazy').scrollTop + $('lazy').clientHeight >= $('lazy').scrollHeight - 5) lazy().catch(report); };
let ticket, cvUpload, job;
$('ats').onsubmit = async event => {
  event.preventDefault();
  try {
    const result = await api('step', {vacancy: 7, name: $('name').value, email: $('email').value,
      role: $('role').value, consent: $('consent').checked});
    ticket = result.ticket; $('validation').textContent = JSON.stringify(result);
    setTimeout(async () => {
      try { const state = await api('state'); $('validation').textContent = state.steps[ticket] ? 'Validated' : 'Pending'; }
      catch (error) { report(error); }
    }, 500);
  } catch (error) { report(error); }
};
async function upload(id, purpose) {
  const file = $(id).files[0]; if (!file) throw new Error('Choose a generated fixture file');
  if (file.size > 100000) throw new Error('Fixture file too large');
  const bytes = new Uint8Array(await file.arrayBuffer());
  const encoded = btoa(Array.from(bytes, x => String.fromCharCode(x)).join(''));
  return api('upload', {base64: encoded, purpose, item: 7});
}
button('uploadcv', async () => { cvUpload = (await upload('cv', 'cv')).upload; });
const attempt = crypto.randomUUID();
button('submit', async () => { $('receipt').textContent = JSON.stringify(await api('submit', {vacancy: 7, ticket, upload: cvUpload, attempt})); });
button('refresh', async () => { $('conversation').textContent = JSON.stringify(await api('state')); });
button('send', async () => { $('sent').textContent = JSON.stringify(await api('send', {approval: $('approval').value, recipient: $('recipient').value, text: $('draft').value})); });
button('process', async () => {
  const uploadResult = await upload('media', 'media');
  const result = await api('process', {upload: uploadResult.upload}); job = result.job;
  $('job').textContent = JSON.stringify(result);
});
button('poll', async () => {
  const state = (await api('state')).jobs[job]; $('job').textContent = state ?? 'No job';
  if (state === 'complete') {
    $('outputs').replaceChildren();
    for (const name of ['output.mp3', 'transcript.txt']) {
      const link = document.createElement('a'); link.href = `${C.base}download/${name}?job=${job}`;
      link.download = name; link.textContent = name; $('outputs').append(link, document.createElement('br'));
    }
  }
});
button('rerender', () => { const next = document.createElement('button'); next.id = 'stale'; next.textContent = 'Replacement control'; $('replacement').replaceChildren(next); });
button('showoverlay', () => { $('overlay').style.display = 'block'; });
button('dismiss', () => { $('overlay').style.display = 'none'; });
setTimeout(() => { const node = document.createElement('button'); node.id = 'late'; node.textContent = 'Delayed control'; $('delayed').append(node); }, 350);
const shadow = $('shadow').attachShadow({mode: 'open'});
const shadowButton = document.createElement('button'); shadowButton.textContent = 'Shadow button';
shadowButton.onclick = () => window.fixtureEvent('shadow-click'); shadow.append(shadowButton);
const context = $('visual').getContext('2d'); context.fillStyle = '#cf335f'; context.beginPath(); context.arc(50, 40, 20, 0, Math.PI * 2); context.fill();
if (!C.frame) for (const [label, source] of [['same-origin', C.base + 'frame'], ['cross-origin', C.peer + 'cross-frame']]) {
  const frame = document.createElement('iframe'); frame.title = label; frame.src = source; $('frames').append(frame);
}
button('site', () => api('site-delay', {}));
search().catch(report); lazy().catch(report);
