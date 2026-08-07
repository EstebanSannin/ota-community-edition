// Console accounts (local-users auth). Talks to the auth sidecar via the front proxy at /auth/*.
// The console stays user-agnostic: it probes /auth/api/me, and only reveals the Users nav + the
// header "signed in as" widget when local-users auth is actually in front (otherwise those calls
// 404/401 and the UI stays hidden — e.g. a no-auth LAN or GitHub-login deployment).
import { esc, fmtTime, relTime } from '../lib/api.js';
import { uiConfirm } from '../lib/dialogs.js';
import { expose, toast } from '../lib/ui.js';

// Probe who we are and reveal/gate the account UI. Returns null when no local-users auth is in
// front (e.g. a trusted-LAN no-auth deploy or GitHub-login mode) — in which case we leave every
// nav item as-is. When auth IS in front, the admin-only pages (System, Users) are shown only to
// admins.
async function loadMe(){
  let me;
  try {
    const r = await fetch('/auth/api/me', {headers:{'Accept':'application/json'}});
    if(!r.ok) return null;
    me = await r.json();
  } catch(e){ return null; }
  const w = document.getElementById('whoami'); const n = document.getElementById('whoami-name');
  if(n) n.textContent = me.username + (me.admin ? '' : ' (user)');
  if(w) w.style.display = 'inline-flex';
  const users = document.getElementById('nav-users-link');
  const system = document.getElementById('nav-system-link');
  if(users) users.style.display = me.admin ? '' : 'none';       // admin-only
  if(system) system.style.display = me.admin ? '' : 'none';     // admin-only
  return me;
}

async function logout(){
  try { await fetch('/logout', {method:'POST'}); } catch(e){}
  window.location = '/login';
}

async function loadUsers(){
  const el = document.getElementById('users-list'); if(!el) return;
  let vals;
  try {
    const r = await fetch('/auth/api/users', {headers:{'Accept':'application/json'}});
    if(r.status === 401){ el.innerHTML = '<div class="empty">Session expired — <a href="/login">sign in again</a>.</div>'; return; }
    if(!r.ok) throw new Error('HTTP ' + r.status);
    vals = (await r.json()).values || [];
  } catch(e){
    el.innerHTML = '<div class="empty">Local-users auth is not enabled on this instance.</div>';
    return;
  }
  const c = document.getElementById('users-count'); if(c) c.textContent = vals.length;
  const me = document.getElementById('whoami-name') ? document.getElementById('whoami-name').textContent : '';
  el.innerHTML = `<table><thead><tr><th>Username</th><th>Created</th><th class="right">Actions</th></tr></thead><tbody>${
    vals.map(u => {
      const n = esc(u.username), nj = u.username.replace(/'/g, "\\'");
      const isMe = u.username === me;
      return `<tr><td><b>${n}</b>${u.admin ? ' <span class="tag">admin</span>' : ''}${isMe ? ' <span class="tag">you</span>' : ''}${u.disabled ? ' <span class="tag">disabled</span>' : ''}</td>`
           + `<td class="muted">${esc(relTime(u.created_at * 1000))} <span class="muted">(${esc(fmtTime(u.created_at * 1000))})</span></td>`
           + `<td class="right"><button class="btn sm" onclick="resetUserPassword('${nj}')">Reset password</button> `
           + `<button class="btn sm danger" ${isMe ? 'disabled title="You cannot delete your own account"' : ''} onclick="deleteUser('${nj}')">Delete</button></td></tr>`;
    }).join('')}</tbody></table>`;
}

// A small modal (username + password, and an admin toggle when creating). Reused with the username
// locked and the admin toggle hidden for a password reset.
function credModal({title, user, ok, showAdmin, onsubmit}){
  const ov = document.createElement('div'); ov.className = 'modal open';
  ov.innerHTML = `<div class="m"><header><h3>${esc(title)}</h3></header>
    <div class="form" style="padding:16px 20px">
      <div><label><span class="l">Username</span>
        <input id="cu-user" autocomplete="off" ${user ? `value="${esc(user)}" readonly` : 'placeholder="jane"'}></label></div>
      <div><label><span class="l">Password</span>
        <input id="cu-pass" type="password" autocomplete="new-password" placeholder="at least 8 characters"></label></div>
      ${showAdmin ? `<div><label style="display:flex;align-items:center;gap:9px;cursor:pointer;font-size:13.5px">
        <input type="checkbox" id="cu-admin" style="width:16px;height:16px">
        <span>Administrator <span class="muted">— can see the System page and manage users</span></span></label></div>` : ''}
      <div class="msg" id="cu-msg"></div>
    </div>
    <footer><button class="btn mcancel">Cancel</button><span class="grow"></span><button class="btn primary" id="cu-ok">${esc(ok)}</button></footer></div>`;
  document.body.appendChild(ov);
  const close = () => ov.remove();
  ov.querySelector('.mcancel').onclick = close;
  ov.addEventListener('mousedown', e => { if(e.target === ov) close(); });
  ov.querySelector(user ? '#cu-pass' : '#cu-user').focus();
  ov.querySelector('#cu-ok').onclick = async () => {
    const u = (ov.querySelector('#cu-user').value || '').trim();
    const p = ov.querySelector('#cu-pass').value || '';
    const msg = ov.querySelector('#cu-msg');
    if(!u){ msg.className = 'msg show err'; msg.textContent = 'Username is required.'; return; }
    if(p.length < 8){ msg.className = 'msg show err'; msg.textContent = 'Password must be at least 8 characters.'; return; }
    const admin = !!(ov.querySelector('#cu-admin') && ov.querySelector('#cu-admin').checked);
    const btn = ov.querySelector('#cu-ok'); btn.disabled = true;
    try { await onsubmit(u, p, admin); close(); }
    catch(e){ msg.className = 'msg show err'; msg.textContent = (e.message || e).toString().slice(0, 160); btn.disabled = false; }
  };
}

function openAddUser(){
  credModal({title:'Add user', ok:'Create', showAdmin:true, onsubmit: async (username, password, admin) => {
    const r = await fetch('/auth/api/users', {method:'POST', headers:{'Content-Type':'application/json'},
                                              body: JSON.stringify({username, password, admin})});
    if(!r.ok) throw new Error((await r.json()).error || ('HTTP ' + r.status));
    toast('User "' + username + '" created' + (admin ? ' (admin)' : '')); loadUsers();
  }});
}

function resetUserPassword(username){
  credModal({title:'Reset password — ' + username, user:username, ok:'Set password', onsubmit: async (_u, password) => {
    const r = await fetch('/auth/api/users/' + encodeURIComponent(username) + '/password',
                          {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({password})});
    if(!r.ok) throw new Error((await r.json()).error || ('HTTP ' + r.status));
    toast('Password reset — any active sessions for "' + username + '" were signed out'); loadUsers();
  }});
}

async function deleteUser(username){
  if(!(await uiConfirm({title:'Delete user', message:'Delete "' + username + '"? Their active sessions end immediately.', ok:'Delete', danger:true}))) return;
  try {
    const r = await fetch('/auth/api/users/' + encodeURIComponent(username), {method:'DELETE'});
    if(!r.ok) throw new Error((await r.json()).error || ('HTTP ' + r.status));
    toast('User deleted'); loadUsers();
  } catch(e){ toast('Delete failed: ' + (e.message || e)); }
}

export { loadMe, loadUsers };

expose({ deleteUser, loadUsers, logout, openAddUser, resetUserPassword });   // referenced by inline on*= handlers
