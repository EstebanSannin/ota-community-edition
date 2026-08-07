// Remote access: arming sessions, the sessions view, and the web terminal.
import { api, bytes, esc, relTime } from '../lib/api.js';
import { uiConfirm, uiPrompt } from '../lib/dialogs.js';
import { avatar, expose, setStatus, toast } from '../lib/ui.js';
import { CUR, DEVICES } from '../state.js';

// ---------- remote access (RAC reverse-SSH via ras) ----------
function opKeysList(){let s=localStorage.getItem('opSshKeys');if(s===null)s=localStorage.getItem('opSshPubkey')||'';return s.split(/\n+/).map(x=>x.trim()).filter(Boolean);}
async function remoteAccess(){
  const uuid=CUR&&CUR.uuid; if(!uuid)return;
  let keys=opKeysList();
  if(!keys.length){
    const k=((await uiPrompt({title:'Your SSH public key',label:'Paste your PUBLIC key — it will be authorized on the device for this session',placeholder:'ssh-ed25519 AAAA… you@laptop',ok:'Save & continue'}))||'').trim();
    if(!k)return;
    localStorage.setItem('opSshKeys',k); keys=[k];
  }
  toast('Arming remote access…');
  const ttl=Number(localStorage.getItem('raTtl')||1800);
  try{
    const r=await api('/api/ras/sessions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({uuid,operator_pubkeys:keys,ttl_secs:ttl})});
    showRemoteModal(typeof r==='object'?r:JSON.parse(r));
  }catch(e){toast('Remote access unavailable — is the ras service deployed? ('+(e.message||e)+')');}
}
async function stopRemoteAccess(uuid,ov){
  try{await api('/api/ras/sessions/'+encodeURIComponent(uuid),{method:'DELETE'});toast('Remote access stopped');}
  catch(e){toast('Stop failed: '+(e.message||e));}
  if(ov)ov.remove();
}
function showRemoteModal(r){
  const cmd=r.ssh_command||'';const uuid=CUR&&CUR.uuid;
  const ov=document.createElement('div');ov.className='modal open';
  ov.innerHTML=`<div class="m ramodal"><header><h3>Remote access ready</h3></header>
    <div class="mbody">
      <p class="mmsg" style="margin:0 0 10px">Run this on your computer — the device connects within a few seconds:</p>
      <div class="cmdbox"><code id="ra-cmd"></code><button class="btn sm" id="ra-copy">Copy</button></div>
      <p class="muted" style="font-size:12px;margin:10px 0 0">Authorized with your saved SSH key. Session expires ${r.expires_at?relTime(r.expires_at):'in 30 min'}. Reverse port ${esc(String(r.reverse_port||''))}.</p>
    </div>
    <footer><button class="btn dbad" id="ra-stop">Stop remote access</button><span class="grow"></span><button class="btn" id="ra-web">⧉ Open web terminal</button><button class="btn mok primary">Done</button></footer></div>`;
  ov.querySelector('#ra-cmd').textContent=cmd;
  ov.querySelector('#ra-copy').onclick=()=>{navigator.clipboard&&navigator.clipboard.writeText(cmd);toast('Copied');};
  ov.querySelector('#ra-stop').onclick=()=>stopRemoteAccess(uuid,ov);
  const nm=(CUR&&CUR.device&&(CUR.device.deviceName||CUR.device.deviceId))||uuid;
  ov.querySelector('#ra-web').onclick=()=>openTerminal(uuid,nm);
  ov.querySelector('.mok').onclick=()=>ov.remove();
  ov.addEventListener('mousedown',e=>{if(e.target===ov)ov.remove();});
  document.body.appendChild(ov);
}
// ---------- Remote Access section (left-nav) ----------
function renderRemote(){
  renderOpKeys();
  const sel=document.getElementById('ra-ttl'); if(sel)sel.value=localStorage.getItem('raTtl')||'1800';
  loadRaSessions();
}
function keyMeta(line){
  const p=(line||'').trim().split(/\s+/);
  const type=p[0]||''; const b64=p[1]||''; const comment=p.slice(2).join(' ');
  const label=type.replace(/^ssh-/,'').replace(/^ecdsa-sha2-nistp/,'ecdsa-').replace(/-cert-v01@openssh\.com$/,'');
  return {type,b64,comment,label};
}
async function keyFingerprint(b64){
  try{
    if(!b64||!(window.crypto&&crypto.subtle))return '';
    const bytes=Uint8Array.from(atob(b64),c=>c.charCodeAt(0));
    const dig=await crypto.subtle.digest('SHA-256',bytes);
    return 'SHA256:'+btoa(String.fromCharCode.apply(null,new Uint8Array(dig))).replace(/=+$/,'');
  }catch(e){return '';}
}
function renderOpKeys(){
  const el=document.getElementById('ra-key-list'); if(!el)return;
  const keys=opKeysList();
  if(!keys.length){el.innerHTML='<div class="empty" style="padding:18px 12px">No keys yet. Click <b>Add key</b> to authorize your SSH public key.</div>';return;}
  el.innerHTML=keys.map((k,i)=>{
    const m=keyMeta(k);
    return `<div class="keyrow"><span class="kt">${esc(m.label||'key')}</span>`
      +`<div class="ki"><div class="kc">${esc(m.comment||'(no comment)')}</div><div class="kf mono muted" id="ra-fp-${i}">${esc(m.b64.slice(0,22))}…</div></div>`
      +`<button class="krm" title="Remove key" onclick="removeOpKey(${i})"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 6l12 12M18 6L6 18"/></svg></button></div>`;
  }).join('');
  keys.forEach((k,i)=>{keyFingerprint(keyMeta(k).b64).then(fp=>{const e=document.getElementById('ra-fp-'+i);if(e&&fp)e.textContent=fp;});});
}
async function addOpKey(){
  const raw=((await uiPrompt({title:'Add an SSH public key',label:'Paste a PUBLIC key. It will be authorized on the device for every remote-access session. You can paste several at once (one per line).',placeholder:'ssh-ed25519 AAAA… you@laptop',ok:'Add key',multiline:true}))||'').trim();
  if(!raw)return;
  const lines=raw.split(/\n+/).map(x=>x.trim()).filter(Boolean);
  const bad=lines.find(l=>!/^(ssh-(ed25519|rsa|ecdsa)|ecdsa-sha2-)\S*\s+\S/.test(l));
  if(bad)return toast('Not an SSH public key: '+bad.slice(0,24)+'…');
  const cur=opKeysList(); let added=0;
  lines.forEach(l=>{if(!cur.includes(l)){cur.push(l);added++;}});
  localStorage.setItem('opSshKeys',cur.join('\n')); renderOpKeys();
  toast(added?('Key added — '+cur.length+' authorized'):'Already saved');
}
async function removeOpKey(i){
  const cur=opKeysList(); if(i<0||i>=cur.length)return;
  const m=keyMeta(cur[i]);
  if(!(await uiConfirm({title:'Remove key',message:'Remove '+(m.comment||m.label||'this key')+'? It won\'t be authorized on new sessions.',ok:'Remove',danger:true})))return;
  cur.splice(i,1); localStorage.setItem('opSshKeys',cur.join('\n')); renderOpKeys(); toast('Key removed');
}
async function loadRaSessions(){
  const el=document.getElementById('ra-sessions'); if(!el)return;
  let vals=[];
  try{const r=await api('/api/ras/sessions'); vals=(r&&r.values)||[];}
  catch(e){el.innerHTML='<div class="empty">Remote-access service not reachable — is the <span class="mono">ras</span> service deployed?</div>';const c=document.getElementById('ra-count');if(c)c.textContent='0';const n=document.getElementById('nav-ra');if(n)n.textContent='0';return;}
  const c=document.getElementById('ra-count');if(c)c.textContent=vals.length;
  const n=document.getElementById('nav-ra');if(n)n.textContent=vals.length;
  if(!vals.length){el.innerHTML='<div class="empty">No active sessions. Open a device and click “Remote access”.</div>';return;}
  el.innerHTML=`<table><thead><tr><th>Device</th><th>Reverse port</th><th>Expires</th><th class="right">Action</th></tr></thead><tbody>${vals.map(s=>{
    const d=DEVICES.find(x=>x.uuid===s.uuid);const nm=d?(d.deviceName||d.deviceId):s.uuid;
    const exp=s.expires_at?relTime(s.expires_at):'—';
    const nmj=esc(nm).replace(/'/g,"\\'");
    return `<tr><td><div class="dev"><span class="av" style="width:28px;height:28px;border-radius:7px">${avatar}</span><div class="nm">${esc(nm)}</div></div></td><td class="mono">${esc(String(s.reverse_port))}</td><td class="muted">${esc(exp)}</td><td class="right"><button class="btn sm" onclick="openTerminal('${esc(s.uuid)}','${nmj}')">Terminal</button> <button class="btn sm danger" onclick="killSession('${esc(s.uuid)}')">Kill</button></td></tr>`;
  }).join('')}</tbody></table>`;
}
function saveTtl(){const v=document.getElementById('ra-ttl').value;localStorage.setItem('raTtl',v);toast('Default duration saved');}
// ---------- web terminal (xterm.js <-> ras WS <-> reverse tunnel <-> device sshd) ----------
function openTerminal(uuid,name){
  if(typeof Terminal==='undefined'){toast('Terminal library failed to load');return;}
  const FitCtor=(window.FitAddon&&window.FitAddon.FitAddon)||window.FitAddon;
  const ov=document.createElement('div');ov.className='modal open';
  ov.innerHTML=`<div class="m termmodal"><header><h3>Terminal — ${esc(name||uuid)}</h3><span class="grow"></span><span class="termstatus" id="term-status">connecting…</span><button class="btn sm mcancel">Close</button></header>
    <div class="termhost" id="term-host"></div></div>`;
  document.body.appendChild(ov);
  const status=ov.querySelector('#term-status');
  const term=new Terminal({fontFamily:"ui-monospace,SFMono-Regular,Menlo,Consolas,monospace",fontSize:13,cursorBlink:true,scrollback:5000,
    theme:{background:'#0b0f14',foreground:'#e9eef5',cursor:'#25d0bf',selectionBackground:'#2b3a4d'}});
  let fit=null; if(FitCtor){try{fit=new FitCtor();term.loadAddon(fit);}catch(e){}}
  term.open(ov.querySelector('#term-host'));
  try{fit&&fit.fit();}catch(e){}
  const proto=location.protocol==='https:'?'wss':'ws';
  const ws=new WebSocket(`${proto}://${location.host}/api/ras/terminal/${encodeURIComponent(uuid)}`);
  ws.binaryType='arraybuffer';
  const setStatus=(t,cls)=>{status.textContent=t;status.className='termstatus'+(cls?' '+cls:'');};
  const enc=new TextEncoder();
  function sendResize(){if(ws.readyState===1)ws.send(JSON.stringify({resize:{cols:term.cols,rows:term.rows}}));}
  ws.onopen=()=>{setStatus('connected','ok');term.focus();sendResize();};
  ws.onmessage=(e)=>{if(typeof e.data==='string')term.write(e.data);else term.write(new Uint8Array(e.data));};
  ws.onerror=()=>setStatus('error','bad');
  ws.onclose=()=>{setStatus('disconnected','bad');try{term.write('\r\n\x1b[90m[connection closed]\x1b[0m\r\n');}catch(e){}};
  term.onData(d=>{if(ws.readyState===1)ws.send(enc.encode(d));});
  const onResize=()=>{try{fit&&fit.fit();}catch(e){}sendResize();};
  window.addEventListener('resize',onResize);
  function close(){window.removeEventListener('resize',onResize);try{ws.close();}catch(e){}try{term.dispose();}catch(e){}ov.remove();}
  ov.querySelector('.mcancel').onclick=close;
  ov.addEventListener('mousedown',e=>{if(e.target===ov)close();});
}
async function killSession(uuid){
  if(!(await uiConfirm({title:'Kill session?',message:'Stop the remote-access tunnel for this device now?',ok:'Kill',danger:true})))return;
  try{await api('/api/ras/sessions/'+encodeURIComponent(uuid),{method:'DELETE'});toast('Session killed');}catch(e){toast('Kill failed: '+(e.message||e));}
  renderRemote();
}

export { loadRaSessions, remoteAccess, renderRemote };

expose({ addOpKey, killSession, openTerminal, remoteAccess, removeOpKey, renderRemote, saveTtl });   // referenced by inline on*= handlers
