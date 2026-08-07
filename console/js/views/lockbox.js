// Offline updates ("Lockboxes"): list, create from packages, download as .zip, delete.
import { api, esc, rapi, relTime } from '../lib/api.js';
import { uiConfirm } from '../lib/dialogs.js';
import { expose, toast } from '../lib/ui.js';

const dapiLb = p => '/api/director/admin/repo/offline-updates/' + p;

// Read targets.json straight from the image repo: a lockbox must carry each target's exact
// hash/length/custom, so use the signed metadata rather than the view model in packages.js.
async function fetchOwnTargets(){
  const r = await api(rapi('targets.json'));
  const t = (r.signed || r).targets || {};
  return Object.entries(t).map(([key, v]) => ({
    key,
    name: (v.custom || {}).name || key,
    version: (v.custom || {}).version || '',
    hw: (v.custom || {}).hardwareIds || [],
    hashes: v.hashes || {},
    length: v.length || 0,
    custom: v.custom || {},
  }));
}

async function renderLockboxes(){
  const el = document.getElementById('lb-list'); if(!el) return;
  let vals = [];
  try { const r = await api('/api/lockboxes'); vals = (r && r.values) || []; }
  catch(e){
    el.innerHTML = '<div class="empty">Lockbox service not reachable — is the <span class="mono">lockbox</span> service deployed?</div>';
    setCounts(0); return;
  }
  setCounts(vals.length);
  if(!vals.length){
    el.innerHTML = '<div class="empty">No lockboxes yet. Click “New lockbox” to bundle packages for offline install.</div>';
    return;
  }
  el.innerHTML = `<table><thead><tr><th>Lockbox</th><th>Packages</th><th>Expires</th><th class="right">Actions</th></tr></thead><tbody>${
    vals.map(l => {
      const n = esc(l.name), nj = n.replace(/'/g, "\\'");
      const pkgs = (l.targets || []).length;
      const list = (l.targets || []).slice(0, 3).map(t => `<span class="tag">${esc(t)}</span>`).join(' ')
                 + (pkgs > 3 ? ` <span class="muted">+${pkgs - 3}</span>` : '');
      return `<tr><td><b>${n}</b></td><td>${list || '<span class="muted">—</span>'}</td>`
           + `<td class="muted">${l.expires ? esc(relTime(l.expires)) : '—'}</td>`
           + `<td class="right"><button class="btn sm" onclick="downloadLockbox('${nj}')">⤓ Download .zip</button> `
           + `<button class="btn sm danger" onclick="deleteLockbox('${nj}')">Delete</button></td></tr>`;
    }).join('')}</tbody></table>`;
}

function setCounts(n){
  const c = document.getElementById('lb-count'); if(c) c.textContent = n;
  const b = document.getElementById('nav-lb'); if(b) b.textContent = n;
}

function downloadLockbox(name){
  toast('Building ' + name + '.zip…');
  window.location = '/api/lockbox/' + encodeURIComponent(name) + '.zip';
}

async function deleteLockbox(name){
  if(!(await uiConfirm({title:'Delete lockbox', message:'Delete “' + name + '”? Bundles already downloaded keep working.', ok:'Delete', danger:true}))) return;
  try { await api(dapiLb(encodeURIComponent(name)), {method:'DELETE'}); toast('Lockbox deleted'); renderLockboxes(); }
  catch(e){ toast('Delete failed: ' + (e.message || e)); }
}

// ---- create ----
async function openNewLockbox(){
  let pkgs = [];
  try { pkgs = await fetchOwnTargets(); }
  catch(e){ return toast('Could not load packages: ' + (e.message || e)); }
  if(!pkgs.length) return toast('Upload a package first — a lockbox bundles your own packages.');
  const ov = document.createElement('div'); ov.className = 'modal open';
  ov.innerHTML = `<div class="m"><header><h3>New lockbox</h3></header>
    <div class="form" style="padding:16px 20px">
      <div><label><span class="l">Name</span><input id="lb-name" placeholder="factory-line-1" autocomplete="off"></label></div>
      <div><span class="lbl2">Packages to include</span>
        <div id="lb-pick" style="max-height:260px;overflow:auto;border:1px solid var(--border);border-radius:9px;padding:6px">
          ${pkgs.map((p,i) => `<label style="display:flex;align-items:center;gap:9px;padding:7px 8px;cursor:pointer;font-size:13.5px">
            <input type="checkbox" data-i="${i}" style="width:16px;height:16px">
            <span><b>${esc(p.name)}</b> <span class="muted mono">${esc(p.version || '')}</span>
            ${(p.hw || []).slice(0,1).map(h => `<span class="tag">${esc(h)}</span>`).join('')}</span></label>`).join('')}
        </div></div>
      <div class="msg" id="lb-msg"></div>
    </div>
    <footer><button class="btn mcancel">Cancel</button><span class="grow"></span><button class="btn primary" id="lb-ok">Create lockbox</button></footer></div>`;
  document.body.appendChild(ov);
  const close = () => ov.remove();
  ov.querySelector('.mcancel').onclick = close;
  ov.addEventListener('mousedown', e => { if(e.target === ov) close(); });
  ov.querySelector('#lb-name').focus();
  ov.querySelector('#lb-ok').onclick = async () => {
    const name = (ov.querySelector('#lb-name').value || '').trim();
    const msg = ov.querySelector('#lb-msg');
    if(!/^[A-Za-z0-9._-]{1,80}$/.test(name)){
      msg.className = 'msg show err'; msg.textContent = 'Name: letters, digits, dot, dash or underscore (max 80).'; return;
    }
    const chosen = [...ov.querySelectorAll('#lb-pick input:checked')].map(c => pkgs[+c.dataset.i]);
    if(!chosen.length){ msg.className = 'msg show err'; msg.textContent = 'Pick at least one package.'; return; }
    const values = {};
    chosen.forEach(p => { values[p.key] = {hashes: p.hashes, length: p.length, custom: p.custom}; });
    const btn = ov.querySelector('#lb-ok'); btn.disabled = true;
    try {
      await api(dapiLb(encodeURIComponent(name)), {method:'POST', headers:{'Content-Type':'application/json'},
                                                   body: JSON.stringify({values})});
      close(); toast('Lockbox “' + name + '” created'); renderLockboxes();
    } catch(e){
      msg.className = 'msg show err'; msg.textContent = 'Create failed: ' + (e.message || e).toString().slice(0, 160);
      btn.disabled = false;
    }
  };
}

export { renderLockboxes };

expose({ deleteLockbox, downloadLockbox, openNewLockbox, renderLockboxes });   // referenced by inline on*= handlers
