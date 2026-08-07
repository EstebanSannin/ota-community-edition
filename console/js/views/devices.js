// Devices list: table, filters, selection, bulk actions.
import { api, dapi, esc, relTime } from '../lib/api.js';
import { uiConfirm } from '../lib/dialogs.js';
import { avatar, expose, pillClass, toast } from '../lib/ui.js';
import { go } from '../router.js';
import { CUR, DEVICES, INSTALLED, setDevices } from '../state.js';
import { openDevice } from './device.js';

const SEL = new Set(), FTAGS = new Set();   // selected uuids + active tag filters

// ---------- devices list ----------
async function loadDevices(){
  const d=await api(dapi('devices')); setDevices(d.values||[]);
  await Promise.all(DEVICES.map(async dev=>{try{const ecus=await api('/api/director/admin/devices/'+dev.uuid+'/ecus');
    INSTALLED[dev.uuid]=ecus||[];}catch(e){INSTALLED[dev.uuid]=[];}}));
  renderDevices();
}
function primaryOf(uuid){return (INSTALLED[uuid]||[]).find(e=>e.primary)||(INSTALLED[uuid]||[])[0]||null;}
function verOf(uuid){const p=primaryOf(uuid);const f=p&&p.image&&p.image.filepath;return (f&&f!=='unknown')?f.split('/').pop():null;}
function hwOf(uuid){const p=primaryOf(uuid);return p?p.hardwareId:'';}
function hwSet(uuid){return (INSTALLED[uuid]||[]).map(e=>e.hardwareId).filter(Boolean);}  // all ECUs (primary + secondaries)
function renderDevices(){
  document.getElementById('nav-dev').textContent=DEVICES.length; document.getElementById('dev-count').textContent=DEVICES.length;
  renderDeviceList();
  const prev=DEVICES.slice(0,6).map(d=>`<tr class="click" onclick="openDevice('${esc(d.uuid)}')"><td><div class="dev"><span class="av">${avatar}</span><div class="nm">${esc(d.deviceName||d.deviceId)}</div></div></td><td><span class="pill ${pillClass(d.deviceStatus)}"><span class="d"></span>${esc(d.deviceStatus||'—')}</span></td><td class="mono">${verOf(d.uuid)?esc(verOf(d.uuid)):'<span class="muted">—</span>'}</td></tr>`).join('');
  document.getElementById('dash-devs').innerHTML=DEVICES.length?`<table><thead><tr><th>Device</th><th>Status</th><th>Version</th></tr></thead><tbody>${prev}</tbody></table>`:'<div class="empty">No devices yet.</div>';
  const by={}; DEVICES.forEach(d=>{const c=pillClass(d.deviceStatus);by[c]=(by[c]||0)+1;});
  const utd=DEVICES.length?Math.round(100*(by.ok||0)/DEVICES.length):0;
  document.getElementById('t-dev').textContent=DEVICES.length; document.getElementById('t-dev2').textContent=DEVICES.length;
  document.getElementById('t-dev-m').innerHTML=`${by.ok||0} up to date · ${by.warn||0} updating · ${(by.bad||0)+(by.idle||0)} other`;
  document.getElementById('t-utd').textContent=utd+'%'; document.getElementById('t-utd-m').textContent=`${by.ok||0} of ${DEVICES.length} on target`;
  const seg=(c,col)=>by[c]?`<i style="flex:${by[c]};background:${col}"></i>`:'';
  document.getElementById('fleet').innerHTML=(DEVICES.length?`<div class="meter">${seg('ok','var(--ok)')}${seg('warn','var(--warn)')}${seg('bad','var(--bad)')}${seg('idle','var(--idle)')}</div>`:'')+
    `<div class="legend"><div class="row"><span class="sw" style="background:var(--ok)"></span> Up to date <span class="n num">${by.ok||0}</span></div>
      <div class="row"><span class="sw" style="background:var(--warn)"></span> Updating / outdated <span class="n num">${by.warn||0}</span></div>
      <div class="row"><span class="sw" style="background:var(--bad)"></span> Error <span class="n num">${by.bad||0}</span></div>
      <div class="row"><span class="sw" style="background:var(--idle)"></span> Not seen <span class="n num">${by.idle||0}</span></div></div>`;
}
const trashSvg='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2M6 7l1 13h10l1-13"/></svg>';
function allTags(){const s=new Set();DEVICES.forEach(d=>Object.keys(d.attributes||{}).forEach(t=>s.add(t)));return[...s].sort();}
function filteredDevices(){
  const q=(document.getElementById('devSearch')?.value||'').toLowerCase().trim();
  return DEVICES.filter(d=>{
    if(q){const hay=((d.deviceName||'')+' '+(d.deviceId||'')+' '+(d.uuid||'')).toLowerCase();if(!hay.includes(q))return false;}
    if(FTAGS.size){const dt=Object.keys(d.attributes||{});let hit=false;FTAGS.forEach(t=>{if(dt.includes(t))hit=true;});if(!hit)return false;}
    return true;});
}
function renderDeviceList(){
  const tb=document.getElementById('devToolbar');if(tb)tb.style.display=DEVICES.length?'':'none';
  const tags=allTags();const tc=document.getElementById('devTags');
  if(tc)tc.innerHTML=tags.map(t=>`<button class="tchip ${FTAGS.has(t)?'on':''}" onclick="toggleTagFilter('${esc(t)}')">${esc(t)}${FTAGS.has(t)?' ✕':''}</button>`).join('');
  const list=filteredDevices();
  const bulk=document.getElementById('devBulk');
  if(bulk){if(SEL.size){bulk.style.display='';bulk.innerHTML=`<span><b>${SEL.size}</b> selected</span><span class="grow"></span><button class="btn sm dbad" onclick="bulkDelete()">${trashSvg} Delete selected</button><button class="btn sm ghost" onclick="clearSel()">Clear</button>`;}else bulk.style.display='none';}
  const allOn=list.length>0&&list.every(d=>SEL.has(d.uuid));
  const row=d=>{const sel=SEL.has(d.uuid);return `<tr class="click${sel?' sel':''}" onclick="openDevice('${esc(d.uuid)}')">
      <td class="ck" onclick="event.stopPropagation()"><input type="checkbox" ${sel?'checked':''} onchange="toggleSel('${esc(d.uuid)}',this.checked)"></td>
      <td><div class="dev"><span class="av">${avatar}</span><div class="nm">${esc(d.deviceName||d.deviceId)}</div></div></td>
      <td><span class="pill ${pillClass(d.deviceStatus)}"><span class="d"></span>${esc(d.deviceStatus||'—')}</span></td>
      <td>${hwOf(d.uuid)?`<span class="tag">${esc(hwOf(d.uuid))}</span>`:'<span class="muted">—</span>'}</td>
      <td class="mono">${verOf(d.uuid)?esc(verOf(d.uuid)):'<span class="muted">—</span>'}</td>
      <td class="muted">${relTime(d.lastSeen)}</td></tr>`;};
  const el=document.getElementById('devWrap');if(!el)return;
  el.innerHTML=!DEVICES.length?'<div class="empty">No devices provisioned yet. Click “Provision device”.</div>'
    :!list.length?'<div class="empty">No devices match your search or filter.</div>'
    :`<table><thead><tr><th class="ck"><input type="checkbox" ${allOn?'checked':''} onclick="toggleSelectAll(this.checked)"></th><th>Device</th><th>Status</th><th>Hardware</th><th>Installed version</th><th>Last seen</th></tr></thead><tbody>${list.map(row).join('')}</tbody></table>`;
}
function toggleSel(u,on){on?SEL.add(u):SEL.delete(u);renderDeviceList();}
function toggleSelectAll(on){filteredDevices().forEach(d=>on?SEL.add(d.uuid):SEL.delete(d.uuid));renderDeviceList();}
function clearSel(){SEL.clear();renderDeviceList();}
function toggleTagFilter(t){FTAGS.has(t)?FTAGS.delete(t):FTAGS.add(t);renderDeviceList();}
async function bulkDelete(){return confirmDelete([...SEL]);}
async function confirmDelete(uuids){
  uuids=uuids.filter(u=>DEVICES.some(d=>d.uuid===u));if(!uuids.length)return;
  const names=uuids.map(u=>{const d=DEVICES.find(x=>x.uuid===u)||{};return d.deviceName||d.deviceId||u;});
  const n=uuids.length,shown=names.slice(0,3).join(', ')+(n>3?` +${n-3} more`:'');
  const ok=await uiConfirm({title:n===1?'Delete device?':'Delete '+n+' devices?',
    message:'This permanently removes '+shown+' from this cloud — events, system info, tags and ECU records are deleted. This cannot be undone.',
    ok:n===1?'Delete device':'Delete '+n+' devices',danger:true});
  if(!ok)return;
  let done=0,fail=0;
  for(const u of uuids){try{await api(dapi('devices/'+u),{method:'DELETE'});done++;}catch(e){fail++;}}
  SEL.clear();
  await loadDevices();
  toast(fail?done+' deleted, '+fail+' failed':(n===1?'Device deleted':done+' devices deleted'));
}
async function deleteCurrentDevice(){const u=CUR&&CUR.uuid;if(!u)return;await confirmDelete([u]);if(!DEVICES.some(d=>d.uuid===u))go('devices');}

export { deleteCurrentDevice, hwOf, hwSet, loadDevices, primaryOf, renderDevices, trashSvg, verOf };

expose({ bulkDelete, clearSel, deleteCurrentDevice, renderDeviceList, toggleSel, toggleSelectAll, toggleTagFilter });   // referenced by inline on*= handlers
