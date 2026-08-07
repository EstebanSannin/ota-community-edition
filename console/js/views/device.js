// Device detail page, its mutations, and the rename/notes/tag actions.
import { api, bytes, dapi, esc, fmtTime, relTime, shortHash } from '../lib/api.js';
import { uiConfirm, uiPrompt } from '../lib/dialogs.js';
import { avatar, expose, pillClass, toast } from '../lib/ui.js';
import { go } from '../router.js';
import { CUR, DEVICES, setCur } from '../state.js';
import { deleteCurrentDevice, hwOf, loadDevices, primaryOf, renderDevices, trashSvg, verOf } from './devices.js';
import { deployPrompt } from './packages.js';
import { remoteAccess } from './remote.js';

// ---------- device detail ----------
const H=svg=>`<svg class="hi" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">${svg}</svg>`;
function flat(node,out){ if(!node||typeof node!=='object')return out; if(node.class)out.push(node); (node.children||[]).forEach(c=>flat(c,out)); return out; }
function flatBlk(list,out){ (list||[]).forEach(b=>{ out.push(b); flatBlk(b.children,out); }); return out; }
function mnts(b){ return (b.mountpoints||[]).filter(Boolean); }
function mediaLabel(m){ return String(m).replace(/^.*\/media\//,'').replace(/^\//,'')||m; }
function nicObj(s){ if(s&&typeof s==='object')return s; const p=String(s).split(/\s+/); return {name:(p[0]||'').replace(/@.*/,''),state:p[1]||''}; }
// eMMC health (JEDEC eMMC 5.0): decode raw sysfs hex into a labelled, severity-coloured chip
function emmcLife(lt){const codes=String(lt||'').trim().split(/\s+/).map(x=>parseInt(x,16)).filter(n=>!isNaN(n)&&n>0);
  if(!codes.length)return null;const c=Math.max(...codes);
  if(c>=0x0b)return{label:'life exceeded',sev:'bad'};
  return{label:((c-1)*10)+'–'+(c*10)+'% life used',sev:c>=9?'bad':c>=7?'warn':'ok'};}
function emmcEol(eol){const c=parseInt(String(eol||'').trim(),16);
  if(c===3)return{label:'Urgent',sev:'bad'};if(c===2)return{label:'Warning',sev:'warn'};if(c===1)return{label:'Normal',sev:'ok'};return null;}
function emmcHealth(name){const sh=((CUR&&CUR.sys||{}).ota_report||{}).storage_health||[];
  const h=sh.find(x=>name&&String(name).startsWith(x.dev))||sh[0];if(!h)return null;
  const parts=[emmcLife(h.life_time),emmcEol(h.pre_eol)].filter(Boolean);if(!parts.length)return null;
  const sev=parts.some(p=>p.sev==='bad')?'bad':parts.some(p=>p.sev==='warn')?'warn':'ok';
  return{text:parts.map(p=>p.label).join(' · '),sev,model:h.model||''};}
function healthChip(h){return h?`<span class="health ${h.sev}"><span class="d"></span>${esc(h.text)}</span>`:'';}
function ecuRole(e){const hw=(e.hardwareId||'').toLowerCase();
  if(e.primary)return{label:'Operating system',ic:'<path d="M4 6h16v12H4z"/><path d="M8 10h8M8 14h5"/>'};
  if(hw.includes('docker'))return{label:'Applications',ic:'<path d="M4 7h7v7H4zM13 7h7v4h-7zM13 13h7v4h-7z"/>'};
  if(hw.includes('boot'))return{label:'Bootloader',ic:'<path d="M6 3h12v4H6zM4 7h16v14H4z"/><path d="M8 12h8M8 16h5"/>'};
  if(hw.includes('fuse'))return{label:'Secure fuses',ic:'<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>'};
  return{label:'Subsystem',ic:'<rect x="4" y="7" width="16" height="10" rx="2"/>'};}
function imgLabel(e){const im=e.image||{};let f=im.filepath||'';
  if(!f||f==='unknown'||f==='noimage')return null;
  return f.includes('/')?f.split('/').pop():f;}
async function openDevice(uuid){
  setCur({uuid}); go('device');
  document.getElementById('devDetail').innerHTML='<a class="back" onclick="go(\'devices\')">‹ Devices</a><div class="empty">Loading device…</div>';
  const d=DEVICES.find(x=>x.uuid===uuid)||{};
  const [ecus,sys,pkgs,events]=await Promise.all([
    api('/api/director/admin/devices/'+uuid+'/ecus').catch(()=>[]),
    api(dapi('devices/'+uuid+'/system_info')).catch(()=>({})),
    api(dapi('devices/'+uuid+'/packages?limit=5000')).catch(()=>({values:[],total:0})),
    api(dapi('devices/'+uuid+'/events')).catch(()=>[])
  ]);
  setCur({uuid,device:d,ecus:ecus||[],sys:sys||{},packages:(pkgs.values||[]).map(p=>p.packageId||p),events:Array.isArray(events)?events:[]});
  renderDetail();
}
function renderDetail(){
  const {uuid,device:d,ecus,sys,packages,events}=CUR;
  const o=sys.ota_report||{}; const nodes=flat(sys,[]);
  const board=(nodes.find(n=>n.class==='system')||{}).product || o.device_tree || hwOf(uuid) || '—';
  const procs=nodes.filter(n=>n.class==='processor' && /cpu/i.test((n.product||'')+(n.description||'')) && !/idle|cache/i.test((n.product||'')+(n.id||'')));
  let cores=procs.reduce((a,n)=>a+(parseInt((n.configuration||{}).cores)||0),0); if(!cores)cores=procs.length;
  const freqHz=procs.map(n=>+n.size||+n.capacity||0).filter(Boolean).sort((a,b)=>b-a)[0];
  const freq=freqHz?(freqHz/1e9).toFixed(1)+' GHz':'';
  const cpuModel=procs.map(n=>n.product).find(p=>p && !/^cpu$/i.test(p)) || (cores?cores+'× core'+(cores>1?'s':''):'—');
  const memNode=nodes.find(n=>n.class==='memory' && /system memory/i.test(n.description||'')) || nodes.find(n=>n.class==='memory'&&n.size>1e8);
  const mem=memNode?bytes(memNode.size):null;
  const serial=(sys.serial) || ((nodes.find(n=>n.class==='system')||{}).serial) || (d.deviceId||'').split('-').pop();
  const pri=primaryOf(uuid)||{};
  const osname=o.os_name||'Torizon OS'; const osver=o.os_version||verOf(uuid)||'';
  const blk=flatBlk(o.block_devices,[]);
  // eMMC: the mmc-transport node that actually carries mounts (the partition, not the bare disk)
  const emmc=blk.filter(b=>b.tran==='mmc'&&mnts(b).length).sort((a,b)=>mnts(b).length-mnts(a).length)[0]
           || (o.block_devices||[]).find(b=>b.tran==='mmc'&&/mmcblk\d$/.test(b.name||''));
  const eh=emmcHealth(emmc&&emmc.name);   // eMMC wear/health chip (null if not an eMMC device)
  const usbDevs=(o.usb||[]).filter(s=>!/root hub|Hub Controller|Hub$/i.test(s));
  const usbProduct=(o.usb||[]).map(s=>s.replace(/^Bus.*ID \S+ /,'').trim()).find(s=>s&&!/hub/i.test(s));
  const usbAll=(o.block_devices||[]).filter(b=>b.tran==='usb'&&b.type==='disk');
  const nics=(o.interfaces||[]).map(nicObj);
  const na='<span class="na">not reported yet</span>';
  const evClass=id=>/Completed|Applied|Complete|Success/i.test(id)?'ok':/Fail|Error|Denied/i.test(id)?'bad':'';
  const evs=events.slice().reverse().slice(0,12);

  const subsystems=ecus.map(e=>{const r=ecuRole(e);const img=imgLabel(e);const h=e.image&&e.image.hash&&e.image.hash.sha256;
    return `<div class="ecu"><span class="ic ${e.primary?'prim':'sec'}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">${r.ic}</svg></span>
      <div class="g"><div class="r1"><b>${esc(r.label)}</b>${e.primary?'<span class="tag role">primary</span>':''}<span class="tag">${esc(e.hardwareId)}</span></div>
        ${e.primary?`<div class="r2">${esc(osname)} · ${esc(osver||'—')}</div>`:(img?`<div class="r2 mono">${esc(img)}</div>`:'<div class="r2 none">No image deployed</div>')}
        ${h&&e.primary?`<div class="hash mono">ostree ${esc(shortHash(h))}…</div>`:''}</div>
      <button class="btn ghost" onclick="deployPrompt('${esc(e.hardwareId)}')">Update</button></div>`;}).join('');

  const netRows=nics.filter(n=>n.name&&!/^lo$/.test(n.name)&&!/^(docker|veth|br-|sit0|uap)/.test(n.name)).map(n=>{
    const isUp=/UP/i.test(n.state||'');const kind=/wl|mlan/i.test(n.name)?'Wi-Fi':/can/i.test(n.name)?'CAN bus':'Ethernet';
    const det=[n.mac?'MAC '+n.mac:'',n.ipv4||''].filter(Boolean).join(' · ');
    return `<div class="hwrow ${isUp?'':'down'}"><span class="ic">${netIcon(kind)}</span><div class="g"><div class="t">${esc(kind)} — ${esc(n.name)} ${isUp?'<span class="tag">up</span>':''}</div>${det?`<div class="s mono">${esc(det)}</div>`:''}</div><div class="v">${isUp?'up':'down'}</div></div>`;}).join('');

  document.getElementById('devDetail').innerHTML=`
    <a class="back" onclick="go('devices')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M15 18l-6-6 6-6"/></svg> Devices</a>
    <div class="dhdr">
      <span class="av">${avatar}</span>
      <div class="g">
        <div class="nmrow"><h1 id="dd-name">${esc(d.deviceName||d.deviceId||uuid)}</h1>
          <button class="edit" title="Rename" onclick="renameDevice()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg></button></div>
        <div class="desc ${d.notes?'':'empty'}" onclick="editNotes()" title="Edit description">${d.notes?esc(d.notes):'Add a description…'} <button class="edit"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg></button></div>
        <div class="dmeta">
          <span><b>Status</b> <span class="pill ${pillClass(d.deviceStatus)}"><span class="d"></span>${esc(d.deviceStatus||'—')}</span></span>
          <span><b>Board</b> ${esc(board)}</span>
          ${serial?`<span><b>Serial</b> <span class="mono">${esc(serial)}</span></span>`:''}
          <span><b>Last seen</b> ${relTime(d.lastSeen)}</span>
          <span><b>UUID</b> <span class="mono">${esc(uuid.slice(0,8))}…</span></span>
        </div>
        <div class="tags" id="dd-tags">${Object.entries(d.attributes||{}).map(([k,v])=>`<span class="chip">${esc(k)}${v&&v!=='true'?': '+esc(v):''} <span class="x" onclick="removeTag('${esc(k)}')">×</span></span>`).join('')}<span class="chip add" onclick="addTag()">+ Add tag</span></div>
      </div>
      <div class="dactions">
        <button class="btn primary" onclick="deployPrompt('${esc(hwOf(uuid))}')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12M7 10l5 5 5-5M5 21h14"/></svg>Deploy update</button>
        <button class="btn" onclick="remoteAccess()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M13 15h4"/></svg>Remote access</button>
        <button class="btn" onclick="toast('Rollback isn\\'t wired yet — coming soon')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 14L4 9l5-5"/><path d="M4 9h11a5 5 0 0 1 0 10h-3"/></svg>Roll back</button>
      </div>
    </div>

    <div class="card"><header>${H('<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>')}<h2>Subsystems</h2><span class="count">${ecus.length} ECUs</span></header>
      ${ecus.length?subsystems:'<div class="empty">No ECUs reported.</div>'}
      <div class="note"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v4h1"/></svg><span>Each subsystem is an independently-updatable Uptane ECU. <b>Update</b> assigns a target matching that ECU's hardware id.</span></div></div>

    <div class="grid2">
      <div class="card"><header>${H('<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18M3 12h18"/>')}<h2>Operating system</h2></header>
        <div class="pad"><dl class="kv">
          <dt>Name</dt><dd>${esc(osname)}</dd>
          <dt>Version</dt><dd class="mono">${esc(osver||'—')}</dd>
          <dt>Variant</dt><dd>${esc(o.os_variant||'—')}</dd>
          <dt>Kernel</dt><dd class="mono">${o.kernel?esc(o.kernel):na}</dd>
          <dt>OSTree</dt><dd class="mono">${pri.image&&pri.image.hash?esc(shortHash(pri.image.hash.sha256))+'…':na}</dd>
        </dl></div></div>

      <div class="card"><header>${H('<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v2M15 2v2M9 20v2M15 20v2M2 9h2M2 15h2M20 9h2M20 15h2"/>')}<h2>Hardware</h2></header>
        <div class="pad"><dl class="kv">
          <dt>System</dt><dd>${esc(board)}</dd>
          <dt>CPU</dt><dd>${esc(cpuModel)}${freq?' · '+esc(freq):''}</dd>
          <dt>Cores</dt><dd>${cores||na}</dd>
          <dt>Memory</dt><dd>${mem||na}</dd>
          <dt>CPU governor</dt><dd>${o.cpu_governor?esc(o.cpu_governor):na}</dd>
          <dt>Last boot</dt><dd>${o.last_boot?relTime(o.last_boot):na}</dd>
          ${eh?`<dt>eMMC health</dt><dd>${healthChip(eh)}${eh.model?' <span class="muted" style="font-size:12px">'+esc(eh.model.trim())+'</span>':''}</dd>`:''}
        </dl></div></div>
    </div>

    <div class="card"><header>${H('<rect x="7" y="7" width="10" height="10" rx="1"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>')}<h2>Kernel &amp; boot</h2>${o.kernel?'<span class="rep">reporter</span>':''}</header>
      <div class="pad"><dl class="kv">
        <dt>Kernel</dt><dd class="mono">${o.kernel?esc(o.kernel):na}</dd>
        <dt>Architecture</dt><dd>${o.arch?esc(o.arch):na}</dd>
        <dt>Build</dt><dd class="mono" style="font-size:12px">${o.kernel_build?esc(o.kernel_build):na}</dd>
        <dt>Device tree</dt><dd>${o.device_tree?esc(o.device_tree):na}</dd>
      </dl>
      ${(o.modules&&o.modules.length)?`<details class="disc" style="margin-top:12px"><summary><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" width="12" height="12"><path d="M9 6l6 6-6 6"/></svg>Loaded modules <span class="count">${o.modules.length}</span></summary><div class="modlist" style="padding-top:10px">${o.modules.slice(0,60).map(m=>`<span class="modchip">${esc(m)}</span>`).join('')}${o.modules.length>60?`<span class="modchip muted">… ${o.modules.length-60} more</span>`:''}</div></details>`:''}
      ${o.kernel_cmdline?`<details class="disc"><summary><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" width="12" height="12"><path d="M9 6l6 6-6 6"/></svg>Kernel command line</summary><div class="mono muted" style="font-size:12px;padding-top:8px;overflow-wrap:anywhere">${esc(o.kernel_cmdline)}</div></details>`:''}
      </div></div>

    <div class="card"><header>${H('<rect x="2" y="9" width="20" height="6" rx="1.5"/><path d="M6 12h.01M10 12h.01"/>')}<h2>Storage, network &amp; peripherals</h2></header>
      ${emmc?`<div class="hwrow"><span class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 8h8v8H8z"/></svg></span><div class="g"><div class="t">eMMC — ${esc(emmc.name)} ${healthChip(eh)}</div><div class="s">${[emmc.fstype?esc(String(emmc.fstype).toUpperCase()):'',mnts(emmc).length?'mounted at '+esc(mnts(emmc).slice(0,6).join(', ')):'internal storage'].filter(Boolean).join(' · ')}</div></div><div class="v">${esc(emmc.size||'')}</div></div>`:''}
      ${netRows}
      ${usbAll.map(b=>{const kids=flatBlk(b.children,[]);const labels=kids.flatMap(mnts).map(mediaLabel);
        const s=[esc((b.model||'').trim()),usbProduct?esc(usbProduct):'',labels.length?'mounted: '+esc(labels.join(', ')):''].filter(Boolean).join(' · ')||'USB mass storage';
        return `<div class="hwrow"><span class="ic" style="background:var(--accent-weak);color:var(--accent)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M12 2v14"/><path d="M8 6l4-4 4 4"/><rect x="6" y="16" width="12" height="6" rx="2"/></svg></span><div class="g"><div class="t">USB storage — /dev/${esc(b.name)} <span class="tag" style="background:var(--accent-weak);color:var(--accent)">attached</span></div><div class="s">${s}</div></div><div class="v">${esc(b.size||'')}</div></div>`;}).join('')}
      <div class="hwrow"><span class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M12 2v14"/><path d="M8 6l4-4 4 4"/><rect x="6" y="16" width="12" height="6" rx="2"/></svg></span><div class="g"><div class="t">USB devices</div><div class="s">${usbDevs.length?esc(usbDevs.map(s=>s.replace(/^Bus.*ID \S+ /,'')).join(' · ')):'root hubs only'}</div></div><div class="v muted" style="font-weight:500">${(o.usb||[]).length}</div></div>
      ${o.kernel?'<div class="note"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v4h1"/></svg><span>Peripherals refresh via the on-device reporter (USB hot-plug + timer).</span></div>':''}
      ${nodes.length?`<details class="disc" style="border-top:1px solid var(--border)"><summary><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" width="12" height="12"><path d="M9 6l6 6-6 6"/></svg>Full hardware tree <span class="sub">everything lshw detected</span></summary><div class="discbody"><table class="pkgtbl">${nodes.map(n=>`<tr><td>${esc(n.product||n.description||n.id||n.class)}</td><td class="v">${esc(n.class)}</td></tr>`).join('')}</table></div></details>`:''}</div>

    <details class="card disc"><summary><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" width="12" height="12"><path d="M9 6l6 6-6 6"/></svg>${H('<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 12l8-4.5M12 12v9M12 12L4 7.5"/>')}Installed packages <span class="count">${packages.length}</span><span class="sub">advanced — the OS image package manifest</span></summary>
      <div class="discbody"><input id="dd-pkgfilter" placeholder="filter packages…" oninput="renderPkgs()"><table class="pkgtbl" id="dd-pkgtbl"></table></div></details>

    <div class="card"><header>${H('<path d="M3 3v6h6"/><path d="M3 9a9 9 0 1 0 3-6"/><path d="M12 8v4l3 2"/>')}<h2>Update history</h2><span class="count">${evs.length}</span></header>
      <div class="pad">${evs.length?`<div class="tl">${evs.map(e=>`<div class="ev ${evClass((e.eventType&&e.eventType.id)||'')}"><div class="t">${esc((e.eventType&&e.eventType.id)||'event')}</div><div class="d">${fmtTime(e.deviceTime)}</div></div>`).join('')}</div>`:'<div class="empty">No events yet.</div>'}</div></div>

    <div class="card dz"><header>${H('<path d="M12 9v4M12 17h.01M10.3 3.9 2 18a2 2 0 0 0 1.7 3h16.6a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>')}<h2>Danger zone</h2></header>
      <div class="dzrow"><div class="g"><div class="t">Delete this device</div><div class="s">Removes <b>${esc(d.deviceName||d.deviceId||uuid)}</b> and all its data from this cloud. Cannot be undone.</div></div>
      <button class="btn dbad" onclick="deleteCurrentDevice()">${trashSvg} Delete device</button></div></div>`;
  renderPkgs();
}
function netIcon(kind){return kind==='Wi-Fi'?'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M5 12a10 10 0 0 1 14 0M8.5 15.5a5 5 0 0 1 7 0M12 19h.01"/></svg>':kind==='CAN bus'?'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 12h4l2-3 4 6 2-3h4"/></svg>':'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="2" y="9" width="20" height="6" rx="1.5"/><path d="M6 9V6M18 9V6"/></svg>';}
function renderPkgs(){const el=document.getElementById('dd-pkgtbl');if(!el)return;const f=(document.getElementById('dd-pkgfilter')?.value||'').toLowerCase();
  const list=CUR.packages.filter(p=>!f||(p.name||'').toLowerCase().includes(f)).slice(0,400);
  el.innerHTML=list.length?list.map(p=>`<tr><td>${esc(p.name)}</td><td class="v">${esc(p.version)}</td></tr>`).join(''):'<tr><td class="muted">No matching packages.</td></tr>';}

// ---------- device mutations ----------
async function patchDevice(body,okmsg){try{await api(dapi('devices/'+CUR.uuid),{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const i=DEVICES.findIndex(x=>x.uuid===CUR.uuid);if(i>=0)Object.assign(DEVICES[i],body);Object.assign(CUR.device,body);renderDetail();renderDevices();toast(okmsg);}
  catch(e){toast('Failed: '+e.message);}}

async function renameDevice(){const n=await uiPrompt({title:'Rename device',label:'Device name',value:CUR.device.deviceName||'',placeholder:'my-device-01'});if(n==null)return;const v=n.trim();if(!v||v===CUR.device.deviceName)return;patchDevice({deviceName:v},'Renamed');}
async function editNotes(){const n=await uiPrompt({title:'Edit description',label:'Description',value:CUR.device.notes||'',placeholder:'What is this device for?',multiline:true,ok:'Save'});if(n==null)return;patchDevice({notes:n.trim()},'Description saved');}
async function addTag(){
  const raw=((await uiPrompt({title:'Add tag',label:'Tag — "key" or "key=value"',placeholder:'e.g. env=lab or production'}))||'').trim();
  if(!raw)return;
  const eq=raw.indexOf('=');const key=(eq>=0?raw.slice(0,eq):raw).trim();const val=(eq>=0?raw.slice(eq+1):'true').trim()||'true';
  if(!/^[\w\-]{1,20}$/.test(key))return toast('Tag key must be ≤20 chars: letters, digits, - or _ (no spaces)');
  try{await api(dapi('devices/'+CUR.uuid+'/device_tags'),{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({tagId:key,tagValue:val})});
    await loadDevices();CUR.device=DEVICES.find(d=>d.uuid===CUR.uuid)||CUR.device;renderDetail();toast('Tag added');}
  catch(e){toast('Add tag failed: '+e.message.slice(0,80));}}
async function removeTag(t){
  if(!(await uiConfirm({title:'Remove tag',message:'Remove tag "'+t+'" from every device in this cloud? Tags are namespace-wide on the server, so this deletes it everywhere — not just this device.',ok:'Remove tag',danger:true})))return;
  try{await api(dapi('device_tags/'+encodeURIComponent(t)),{method:'DELETE'});
    await loadDevices();CUR.device=DEVICES.find(d=>d.uuid===CUR.uuid)||CUR.device;renderDetail();toast('Tag removed');}
  catch(e){toast('Remove failed: '+e.message.slice(0,80));}}

export { H, imgLabel, openDevice };

expose({ addTag, editNotes, openDevice, removeTag, renameDevice, renderPkgs });   // referenced by inline on*= handlers
