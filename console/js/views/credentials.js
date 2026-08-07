// Tooling credentials: the credentials.zip that lets torizoncore-builder / garage-sign work
// against this instance. One instance-wide credential — minting a new one revokes the previous.
import { api, esc, fmtTime, relTime } from '../lib/api.js';
import { uiConfirm } from '../lib/dialogs.js';
import { expose, toast } from '../lib/ui.js';

async function loadCredential(){
  const el = document.getElementById('cred-body'); if(!el) return;
  let c;
  try { c = (await api('/api/credentials')).issued; }
  catch(e){
    el.innerHTML = '<div class="empty">Lockbox service not reachable — is the <span class="mono">lockbox</span> service deployed?</div>';
    return;
  }
  const btn = `<button class="btn sm primary" onclick="downloadCredential()">⤓ Download credentials.zip</button>`;
  if(!c){
    el.innerHTML = `<div class="empty" style="display:flex;flex-direction:column;gap:11px;align-items:center">
      <span>No credential issued yet.</span>${btn}</div>`;
    return;
  }
  const issued = c.created_at * 1000;      // the service stores unix *seconds*
  el.innerHTML = `<table><thead><tr><th>Client ID</th><th>Issued</th><th class="right">Actions</th></tr></thead>
    <tbody><tr>
      <td class="mono">${esc(c.client_id)}</td>
      <td>${esc(relTime(issued))} <span class="muted">(${esc(fmtTime(issued))})</span></td>
      <td class="right">${btn} <button class="btn sm danger" onclick="revokeCredential()">Revoke</button></td>
    </tr></tbody></table>`;
}

// POST mints and streams the zip in one response, so this can't be a plain link (that would GET).
// Fetch it as a blob and hand it to a synthetic <a download> instead.
async function downloadCredential(){
  if(!(await uiConfirm({
    title: 'Download credentials.zip',
    message: 'This issues a NEW credential and revokes any previous one, so tooling still using the '
           + 'old secret will stop working. The secret is inside the zip and is shown only once — '
           + 'keep it safe: it can sign packages your whole fleet will trust.',
    ok: 'Issue and download',
  }))) return;
  toast('Issuing credential…');
  try {
    const r = await fetch('/api/credentials', {method:'POST'});
    if(!r.ok) throw new Error('HTTP ' + r.status + ' ' + (await r.text()).slice(0, 160));
    const url = URL.createObjectURL(await r.blob());
    const a = document.createElement('a');
    a.href = url; a.download = 'credentials.zip';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
    toast('credentials.zip downloaded');
    loadCredential();
  } catch(e){ toast('Could not issue credential: ' + (e.message || e)); }
}

async function revokeCredential(){
  if(!(await uiConfirm({title:'Revoke credential',
                        message:'Any tooling using this credential stops working immediately. '
                              + 'Packages already pushed are unaffected.',
                        ok:'Revoke', danger:true}))) return;
  try { await api('/api/credentials', {method:'DELETE'}); toast('Credential revoked'); loadCredential(); }
  catch(e){ toast('Revoke failed: ' + (e.message || e)); }
}

export { loadCredential };

expose({ downloadCredential, loadCredential, revokeCredential });   // referenced by inline on*= handlers
