// Packages: list, sources, upload, detail, and deploy.
import { api, bytes, esc, fmtTime, rapi } from '../lib/api.js';
import { uiConfirm, uiPick } from '../lib/dialogs.js';
import { expose, toast } from '../lib/ui.js';
import { go } from '../router.js';
import { DEVICES, INSTALLED } from '../state.js';
import { H, imgLabel } from './device.js';
import { hwOf, hwSet } from './devices.js';

let TARGETS = [], SOURCES = [], PKGCOUNTS = {}, PKGVIEW = [], PKGCUR = null;
let PKGSRC = 'mine', PKGHW = null, pkgGridSeq = 0;
let PKGLAYOUT = localStorage.getItem('pkgLayout') || 'grid';
let PKGSORT = localStorage.getItem('pkgSort') || 'date';

// ---------- deploy (own + delegated, per hardware id) ----------
async function deployPrompt(hwid){
  const cands=[];
  TARGETS.filter(t=>!hwid||t.hw.includes(hwid)).forEach(t=>cands.push({label:t.name+' '+t.version+' (yours)',target:t.key,hash:t.hash,len:t.length,hw:t.hw[0]}));
  // delegated for this hw
  try{const di=await api(rapi('delegations_items?nameContains='+encodeURIComponent(hwid||'')));(di.values||di||[]).forEach(it=>{const c=(it.clientTargetItem&&it.clientTargetItem.custom)||{},h=(it.clientTargetItem&&it.clientTargetItem.hashes)||{};
    if(!hwid||(c.hardwareIds||[]).includes(hwid))cands.push({label:it.targetFilename.split('/').pop()+' (source)',target:it.targetFilename,hash:h.sha256,len:(it.clientTargetItem&&it.clientTargetItem.length)||0,uri:c.uri,hw:(c.hardwareIds||[])[0]});});}catch(e){}
  if(!cands.length)return toast('No targets available for '+(hwid||'this device'));
  const idx=await uiPick({title:'Deploy to '+(hwid||'device'),options:cands.map(c=>({label:c.label,sub:c.target}))});
  if(idx==null||!cands[idx])return;
  const c=cands[idx]; const to={target:c.target,checksum:{method:'sha256',hash:c.hash},targetLength:c.len||0}; if(c.uri)to.uri=c.uri;
  try{const mtu=(await api('/api/director/multi_target_updates',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({targets:{[c.hw||hwid]:{to}}})})).replace(/"/g,'');
    const res=await api('/api/director/assignments',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({correlationId:'urn:here-ota:mtu:'+mtu,mtuId:mtu,devices:[CUR.uuid]})});
    toast(res&&res.affected&&res.affected.length?'✓ Assigned — installs on next check-in':'Device not affected (hw mismatch or already installed)');
    setTimeout(()=>openDevice(CUR.uuid),1200);
  }catch(e){toast('Deploy failed: '+e.message);}
}

// ---------- packages (unified: my packages + delegated sources) ----------
function pkgIcon(fmt,hw){const s=(hw||'')+' '+(fmt||'');
  if(/docker/i.test(s))return '<path d="M4 7h7v7H4zM13 7h7v4h-7zM13 13h7v4h-7z"/>';
  if(/ostree/i.test(fmt||''))return '<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>';
  return '<rect x="4" y="4" width="16" height="16" rx="2"/>';}
function isCompose(p){return (p.hw||[]).some(h=>/docker/i.test(h));}
function pkgKind(p){return isCompose(p)?'compose':(/ostree/i.test(p.format||'')?'ostree':'binary');}
function pkgLabel(kind){return kind==='compose'?'docker-compose':kind==='ostree'?'OSTree':'binary';}
function parseTarget(filename,c){ // delegated OSTree filename -> friendly display
  const seg=String(filename||'').split('/');
  if(seg.length>=4){return {name:'Torizon OS · '+seg[1], variant:seg[3]||seg[2], branch:seg[0], board:seg[1]};}
  return {name:(c&&c.name)||filename, variant:'', branch:'', board:''};}
function mdInline(s){return s
  .replace(/`([^`]+)`/g,'<code>$1</code>')
  .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')
  .replace(/(^|[^*])\*([^*\n]+)\*/g,'$1<em>$2</em>')
  .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');}
function md(src){const e=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const L=String(src||'').replace(/\r\n?/g,'\n').split('\n');const out=[];let i=0;
  while(i<L.length){let ln=L[i];
    if(/^```/.test(ln)){const b=[];i++;while(i<L.length&&!/^```/.test(L[i])){b.push(e(L[i]));i++;}i++;out.push('<pre class="code">'+b.join('\n')+'</pre>');continue;}
    const h=ln.match(/^(#{1,3})\s+(.*)$/);if(h){const n=h[1].length+3;out.push('<h'+n+'>'+mdInline(e(h[2]))+'</h'+n+'>');i++;continue;}
    if(/^\s*[-*]\s+/.test(ln)){const it=[];while(i<L.length&&/^\s*[-*]\s+/.test(L[i])){it.push('<li>'+mdInline(e(L[i].replace(/^\s*[-*]\s+/,'')))+'</li>');i++;}out.push('<ul>'+it.join('')+'</ul>');continue;}
    if(/^\s*\d+\.\s+/.test(ln)){const it=[];while(i<L.length&&/^\s*\d+\.\s+/.test(L[i])){it.push('<li>'+mdInline(e(L[i].replace(/^\s*\d+\.\s+/,'')))+'</li>');i++;}out.push('<ol>'+it.join('')+'</ol>');continue;}
    if(/^\s*$/.test(ln)){i++;continue;}
    const p=[];while(i<L.length&&!/^\s*$/.test(L[i])&&!/^(#{1,3}\s|```|\s*[-*]\s|\s*\d+\.\s)/.test(L[i])){p.push(e(L[i]));i++;}
    out.push('<p>'+mdInline(p.join('<br>'))+'</p>');}
  return out.join('\n');}
async function loadTargets(){let signed;try{const r=await api(rapi('targets.json'));signed=r.signed||r;}catch(e){TARGETS=[];afterPkgData();return;}
  const t=signed.targets||{};
  TARGETS=Object.entries(t).map(([k,v])=>{const c=v.custom||{};return {key:k,name:c.name||k,version:c.version||'',hw:c.hardwareIds||[],hash:(v.hashes&&v.hashes.sha256)||'',length:v.length||0,format:c.targetFormat||'BINARY',uri:c.uri||null,description:c.description||'',createdAt:c.createdAt||''};});
  afterPkgData();}
async function loadSources(){let roles=[];try{roles=await api(rapi('trusted-delegations'))||[];}catch(e){roles=[];}
  PKGCOUNTS={};try{const di=await api(rapi('delegations_items'));(di.values||di||[]).forEach(it=>{PKGCOUNTS[it.delegatedRoleName]=(PKGCOUNTS[it.delegatedRoleName]||0)+1;});}catch(e){}
  const infos=await Promise.all(roles.map(r=>api(rapi('trusted-delegations/'+encodeURIComponent(r.name)+'/info')).catch(()=>({}))));
  SOURCES=roles.map((r,i)=>({name:r.name,friendlyName:(infos[i]||{}).friendlyName||r.name,paths:r.paths||[],lastFetched:(infos[i]||{}).lastFetched||null,remoteUri:(infos[i]||{}).remoteUri||'',count:PKGCOUNTS[r.name]||0}));
  const ts=document.getElementById('t-src');if(ts)ts.textContent=SOURCES.length;
  const tm=document.getElementById('t-src-m');if(tm)tm.textContent=Object.values(PKGCOUNTS).reduce((a,b)=>a+b,0)+' packages available';
  afterPkgData();}
function afterPkgData(){const t=document.getElementById('t-tgt');if(t)t.textContent=TARGETS.length;const nv=document.getElementById('nav-tgt');if(nv)nv.textContent=TARGETS.length;
  if(document.getElementById('v-packages').classList.contains('active'))renderPackages();}
function setPkgSource(s){PKGSRC=s;PKGHW=null;const el=document.getElementById('pkgSearch');if(el)el.value='';renderPackages();}
function setPkgHw(hw){PKGHW=(PKGHW===hw?null:hw);renderPackages();}
function setPkgLayout(l){PKGLAYOUT=l;localStorage.setItem('pkgLayout',l);renderPackages();}
function setPkgSort(s){PKGSORT=s;localStorage.setItem('pkgSort',s);renderPackages();}
function sortPkgs(arr){const a=arr.slice();
  if(PKGSORT==='name')a.sort((x,y)=>(x.name||'').localeCompare(y.name||''));
  else a.sort((x,y)=>{const c=String(x.createdAt||'').localeCompare(String(y.createdAt||''));return PKGSORT==='date-asc'?c:-c;});
  return a;}
function pkgCard(p,i){const kind=pkgKind(p);
  return `<button class="pk" onclick="openPackage(${i})"><span class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">${pkgIcon(p.format,(p.hw||[]).join(' '))}</svg></span>
    <div class="g"><div class="nm" title="${esc(p.name)}">${esc(p.name)}</div><div class="ver">${esc(p.version||'—')}</div>
      <div class="row"><span class="badge ${kind}">${pkgLabel(kind)}</span>${(p.hw||[]).slice(0,1).map(h=>`<span class="tag">${esc(h)}</span>`).join('')}</div>
      <div class="row"><span class="src">${p.source==='mine'?'My package':esc(p.source)}${p.variant?' · '+esc(p.variant):''}</span></div></div></button>`;}
function pkgRow(p,i){const kind=pkgKind(p);
  return `<tr class="click" onclick="openPackage(${i})"><td><div class="dev"><span class="av" style="width:28px;height:28px;border-radius:7px"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">${pkgIcon(p.format,(p.hw||[]).join(' '))}</svg></span><div class="nm">${esc(p.name)}</div></div></td><td class="mono">${esc(p.version||'—')}</td><td>${(p.hw||[]).slice(0,1).map(h=>`<span class="tag">${esc(h)}</span>`).join('')||'<span class="muted">—</span>'}</td><td><span class="badge ${kind}">${pkgLabel(kind)}</span></td><td class="muted">${p.source==='mine'?'My package':esc(p.source)}</td><td class="muted">${p.createdAt?relTime(p.createdAt):'—'}</td></tr>`;}
function renderPkgItems(list,extraNote){
  if(!list.length)return '<div class="empty">No packages match.</div>';
  if(PKGLAYOUT==='list')return `<div class="tablewrap"><table><thead><tr><th>Name</th><th>Version</th><th>Hardware</th><th>Format</th><th>Source</th><th>Updated</th></tr></thead><tbody>${list.map((p,i)=>pkgRow(p,i)).join('')}</tbody></table></div>${extraNote||''}`;
  return `<div class="pgrid">${list.map((p,i)=>pkgCard(p,i)).join('')}</div>${extraNote||''}`;}
function syncLayoutSwitch(){const sw=document.getElementById('pkgLayoutSwitch');if(sw)sw.querySelectorAll('button').forEach(b=>b.classList.toggle('on',b.dataset.l===PKGLAYOUT));const so=document.getElementById('pkgSort');if(so)so.value=PKGSORT;}
function renderPackages(){
  const seg=document.getElementById('pkgSeg');if(!seg)return;
  seg.innerHTML=`<button class="${PKGSRC==='mine'?'on':''}" onclick="setPkgSource('mine')">My packages <span class="n">${TARGETS.length}</span></button>`+
    SOURCES.map(s=>`<button class="${PKGSRC===s.name?'on':''}" onclick="setPkgSource('${esc(s.name)}')">${esc(s.friendlyName)} <span class="n">${s.count}</span></button>`).join('');
  syncLayoutSwitch();
  const q=(document.getElementById('pkgSearch')?.value||'').toLowerCase().trim();
  const chips=document.getElementById('pkgHwChips'),grid=document.getElementById('pkgGrid');
  if(PKGSRC==='mine'){
    chips.innerHTML='';
    PKGVIEW=sortPkgs(TARGETS.filter(t=>!q||((t.name+' '+t.version+' '+t.hw.join(' ')).toLowerCase().includes(q)))
      .map(t=>({source:'mine',key:t.key,name:t.name,version:t.version,hw:t.hw,format:t.format,hash:t.hash,length:t.length,uri:t.uri,description:t.description,createdAt:t.createdAt})));
    document.getElementById('pkgCount').textContent=PKGVIEW.length;
    grid.innerHTML=PKGVIEW.length?renderPkgItems(PKGVIEW):('<div class="empty">'+(q?'No packages match your search.':'No packages yet — click Upload to add one.')+'</div>');
  } else { renderDelegatedGrid(q); }
}
async function renderDelegatedGrid(q){
  const grid=document.getElementById('pkgGrid'),chips=document.getElementById('pkgHwChips'),seq=++pkgGridSeq;
  grid.innerHTML='<div class="empty">Loading…</div>';
  let items=[];
  try{const di=await api(rapi('delegations_items'+(q?('?nameContains='+encodeURIComponent(q)):'')));items=(di.values||di||[]).filter(it=>it.delegatedRoleName===PKGSRC);}
  catch(e){if(seq!==pkgGridSeq)return;grid.innerHTML='<div class="empty">Error: '+esc(e.message)+'</div>';return;}
  if(seq!==pkgGridSeq)return;
  const hws=[...new Set(items.flatMap(it=>((it.clientTargetItem&&it.clientTargetItem.custom&&it.clientTargetItem.custom.hardwareIds)||[])))].sort();
  chips.innerHTML=hws.slice(0,24).map(h=>`<span class="tchip ${PKGHW===h?'on':''}" onclick="setPkgHw('${esc(h)}')">${esc(h)}</span>`).join('')+(hws.length>24?`<span class="tchip muted">+${hws.length-24} more</span>`:'');
  const list=items.filter(it=>{const hw=(it.clientTargetItem&&it.clientTargetItem.custom&&it.clientTargetItem.custom.hardwareIds)||[];return !PKGHW||hw.includes(PKGHW);});
  PKGVIEW=sortPkgs(list.map(it=>{const c=(it.clientTargetItem&&it.clientTargetItem.custom)||{},h=(it.clientTargetItem&&it.clientTargetItem.hashes)||{},pt=parseTarget(it.targetFilename,c);
    return {source:PKGSRC,filename:it.targetFilename,name:pt.name,version:c.version||'',hw:c.hardwareIds||[],format:c.targetFormat||'',hash:h.sha256||'',length:(it.clientTargetItem&&it.clientTargetItem.length)||0,uri:c.uri||null,variant:pt.variant,branch:pt.branch,board:pt.board,createdAt:c.createdAt||'',sbom:((c.supplyChainInfo||{})['cyclonedx+vex']||{}).url||''};}));
  document.getElementById('pkgCount').textContent=PKGVIEW.length;
  const CAP=PKGLAYOUT==='list'?200:60,shown=PKGVIEW.slice(0,CAP);
  const note=PKGVIEW.length>CAP?`<div class="muted" style="padding:0 18px 16px;font-size:12px">Showing ${CAP} of ${PKGVIEW.length} — refine with search or a hardware filter.</div>`:'';
  grid.innerHTML=renderPkgItems(shown,note);
}

// ---------- sources (managed from the gear modal) ----------
function openSources(){
  const ov=document.createElement('div');ov.className='modal open';ov.id='srcModal';
  ov.innerHTML=`<div class="m"><header><h3>Package sources</h3><span class="grow"></span><button class="iconbtn" onclick="closeSources()" style="width:30px;height:30px;border:0;background:transparent;cursor:pointer;color:var(--text-dim)"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 6l12 12M18 6L6 18"/></svg></button></header>
    <div id="srcList"></div>
    <div class="form" style="border-top:1px solid var(--border);padding:16px 18px">
      <div><label><span class="l">Add a source — paste the delegation config JSON, or a URL to it</span>
        <textarea id="srcJson" rows="3" placeholder='https://…/delegations/add-tdx-quarterly.json  — or paste the JSON'></textarea></label></div>
      <button class="btn primary" id="srcBtn" onclick="addSource()" style="align-self:start">Add source →</button>
      <div class="msg" id="srcMsg"></div>
    </div></div>`;
  ov.addEventListener('mousedown',e=>{if(e.target===ov)closeSources();});
  document.body.appendChild(ov);renderSourcesModal();
}
function closeSources(){const m=document.getElementById('srcModal');if(m)m.remove();}
function renderSourcesModal(){const el=document.getElementById('srcList');if(!el)return;
  el.innerHTML=SOURCES.length?SOURCES.map(s=>`<div class="srcrow"><span class="pill acc"><span class="d"></span>verified</span><div class="grow"><div class="nm">${esc(s.friendlyName)}</div><div class="muted mono" style="font-size:12px">${esc(s.name)} · ${esc((s.paths||[]).join(', '))} · ${s.lastFetched?('fetched '+relTime(s.lastFetched)):'not fetched'}</div></div><span class="tag">${s.count} pkgs</span><button class="btn sm" onclick="editSource('${esc(s.name)}')">Edit</button><button class="btn sm" onclick="refreshSource('${esc(s.name)}')">Refresh</button><button class="btn sm danger" onclick="removeSource('${esc(s.name)}')">Remove</button></div>`).join(''):'<div class="empty">No package sources yet — add one below.</div>';}
function editSource(name){const s=SOURCES.find(x=>x.name===name);if(!s)return;
  const ov=document.createElement('div');ov.className='modal open';ov.id='srcEditModal';
  ov.innerHTML=`<div class="m mini"><header><h3>Edit source</h3></header>
    <div class="mbody">
      <label class="ml">Display name</label><input class="mf" id="seName" placeholder="${esc(s.name)}" style="margin-bottom:12px">
      <label class="ml">Fetch URL</label><input class="mf" id="seUri" style="margin-bottom:4px">
      <div class="muted" style="font-size:12px">Delegation id <span class="mono">${esc(s.name)}</span> and its signing keys/paths come from the signed metadata and can't be changed here — re-add the source to change those.</div>
      <div class="msg" id="seMsg" style="margin-top:10px"></div>
    </div>
    <footer><button class="btn" onclick="closeEditSource()">Cancel</button><button class="btn primary" id="seBtn" onclick="saveSource('${esc(s.name)}')">Save</button></footer></div>`;
  ov.addEventListener('mousedown',e=>{if(e.target===ov)closeEditSource();});
  document.body.appendChild(ov);
  document.getElementById('seName').value=(s.friendlyName&&s.friendlyName!==s.name)?s.friendlyName:'';
  document.getElementById('seUri').value=s.remoteUri||'';
  document.getElementById('seName').focus();}
function closeEditSource(){const m=document.getElementById('srcEditModal');if(m)m.remove();}
async function saveSource(name){const s=SOURCES.find(x=>x.name===name);if(!s)return;
  const fn=document.getElementById('seName').value.trim(),uri=document.getElementById('seUri').value.trim(),msg=document.getElementById('seMsg'),btn=document.getElementById('seBtn');
  if(!uri)return showMsg(msg,'err','Fetch URL is required.');
  btn.disabled=true;showMsg(msg,'ok','Saving…');
  try{await api(rapi('trusted-delegations/'+encodeURIComponent(name)+'/remote'),{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({uri:uri,friendlyName:fn||name})});
    await loadSources();closeEditSource();renderSourcesModal();renderPackages();toast('Source updated');}catch(e){showMsg(msg,'err','Save failed: '+e.message);btn.disabled=false;}}
async function addSource(){const msg=document.getElementById('srcMsg'),btn=document.getElementById('srcBtn');
  const raw=(document.getElementById('srcJson').value||'').trim();
  if(!raw)return showMsg(msg,'err','Paste a delegation URL or its JSON.');
  const isUrl=/^https?:\/\//i.test(raw);
  let cfg;
  try{
    if(isUrl){showMsg(msg,'ok','Fetching '+raw+' …');const r=await fetch(raw);if(!r.ok)throw new Error('HTTP '+r.status);cfg=await r.json();}
    else cfg=JSON.parse(raw);
  }catch(e){return showMsg(msg,'err',isUrl?('Could not fetch/parse that URL: '+e.message):'Invalid JSON — paste the delegation contents, or its URL.');}
  const dm=cfg.delegationMetadata,newKeys=cfg.keys,fu=cfg.fetchUrl;if(!dm||!newKeys||!fu||!dm.name)return showMsg(msg,'err','That config is missing keys, delegationMetadata (with name), or fetchUrl.');
  const uri=(fu&&fu.uri)||fu;
  btn.disabled=true;showMsg(msg,'ok','Registering + verifying…');const HH={'Content-Type':'application/json'};
  try{
    // The keys and roles endpoints REPLACE the whole collection — so merge with what's already
    // registered, otherwise adding a source would silently delete the existing ones.
    const existRoles=(await api(rapi('trusted-delegations')).catch(()=>[]))||[];
    const existKeys=(await api(rapi('trusted-delegations/keys')).catch(()=>[]))||[];
    const sig=k=>(k&&k.keyval&&k.keyval.public)||JSON.stringify(k);
    const seen=new Set(existKeys.map(sig));const mergedKeys=existKeys.slice();
    (newKeys||[]).forEach(k=>{const s=sig(k);if(!seen.has(s)){seen.add(s);mergedKeys.push(k);}});
    const mergedRoles=existRoles.filter(r=>r.name!==dm.name).concat([dm]);
    await api(rapi('trusted-delegations/keys'),{method:'PUT',headers:HH,body:JSON.stringify(mergedKeys)});
    await api(rapi('trusted-delegations'),{method:'PUT',headers:HH,body:JSON.stringify(mergedRoles)});
    await api(rapi('trusted-delegations/'+encodeURIComponent(dm.name)+'/remote'),{method:'PUT',headers:HH,body:JSON.stringify({uri:uri,friendlyName:cfg.friendlyName||dm.name})});
    showMsg(msg,'ok','✓ Source "'+dm.name+'" added and verified.');document.getElementById('srcJson').value='';await loadSources();renderSourcesModal();}catch(e){showMsg(msg,'err','Failed: '+e.message);}finally{btn.disabled=false;}}
async function refreshSource(n){try{await api(rapi('trusted-delegations/'+encodeURIComponent(n)+'/remote/refresh'),{method:'PUT'});toast('Refreshed');await loadSources();renderSourcesModal();}catch(e){toast('Refresh failed: '+e.message);}}
async function removeSource(n){if(!(await uiConfirm({title:'Remove package source',message:'Remove "'+n+'"? Devices will no longer receive targets from this source.',ok:'Remove',danger:true})))return;try{await api(rapi('trusted-delegations/'+encodeURIComponent(n)),{method:'DELETE'});toast('Removed');await loadSources();renderSourcesModal();}catch(e){toast('Remove failed: '+e.message);}}

// ---------- upload (my package) ----------
function openUpload(){
  const ov=document.createElement('div');ov.className='modal open';ov.id='upModal';
  ov.innerHTML=`<div class="m mini"><header><h3>Upload a package</h3></header>
    <div class="mbody">
      <label class="ml">Name</label><input class="mf" id="upName" placeholder="fleet-config" style="margin-bottom:12px">
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px">
        <div><label class="ml">Version</label><input class="mf" id="upVer" placeholder="1.0.0"></div>
        <div><label class="ml">Hardware id</label><input class="mf" id="upHw" placeholder="docker-compose"></div></div>
      <label class="ml">File</label><input class="mf" type="file" id="upFile" style="margin-bottom:12px">
      <label class="ml">Description <span class="muted" style="font-weight:400">— optional, Markdown supported</span></label><textarea class="mf" id="upDesc" rows="4" placeholder="## What this does&#10;- feature one&#10;- feature two&#10;&#10;See &#96;docker-compose.yml&#96;."></textarea>
      <div class="msg" id="upMsg" style="margin-top:10px"></div>
    </div>
    <footer><button class="btn mcancel" onclick="closeUpload()">Cancel</button><button class="btn primary" id="upBtn" onclick="doUpload()">Upload</button></footer></div>`;
  ov.addEventListener('mousedown',e=>{if(e.target===ov)closeUpload();});
  document.body.appendChild(ov);document.getElementById('upName').focus();
}
function closeUpload(){const m=document.getElementById('upModal');if(m)m.remove();}
async function doUpload(){const name=document.getElementById('upName').value.trim(),ver=document.getElementById('upVer').value.trim(),hw=document.getElementById('upHw').value.trim(),file=document.getElementById('upFile').files[0],desc=document.getElementById('upDesc').value.trim(),msg=document.getElementById('upMsg'),btn=document.getElementById('upBtn');
  if(!name||!ver||!hw||!file)return showMsg(msg,'err','Fill name, version, hardware id and pick a file.');
  const target=`${name}-${ver}`,q=`name=${encodeURIComponent(name)}&version=${encodeURIComponent(ver)}&hardwareIds=${encodeURIComponent(hw)}`;const fd=new FormData();fd.append('file',file);
  btn.disabled=true;showMsg(msg,'ok','Uploading '+file.name+'…');
  try{await api(rapi(`targets/${encodeURIComponent(target)}?${q}`),{method:'PUT',body:fd});
    if(desc){try{await api(rapi('proprietary-custom/'+encodeURIComponent(target)),{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({description:desc})});}catch(e){}}
    await loadTargets();closeUpload();PKGSRC='mine';renderPackages();toast('✓ Uploaded '+target);}catch(e){showMsg(msg,'err','Upload failed: '+e.message);btn.disabled=false;}}

// ---------- package detail ----------
async function openPackage(i){const p=PKGVIEW[i];if(!p)return;PKGCUR=p;go('package');
  const el=document.getElementById('pkgDetail');
  el.innerHTML='<a class="back" onclick="go(\'packages\')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M15 18l-6-6 6-6"/></svg> Packages</a><div class="empty">Loading…</div>';
  let compose=null;
  if(p.source==='mine'&&isCompose(p)){try{const r=await fetch(rapi('targets/'+encodeURIComponent(p.key)));if(r.ok)compose=await r.text();}catch(e){}}
  if(PKGCUR!==p)return;
  renderPkgDetail(compose);
}
function renderPkgDetail(compose){const p=PKGCUR;if(!p)return;const kind=pkgKind(p);const mine=p.source==='mine';
  const meta=mine?`<dt>Source</dt><dd>My package</dd><dt>Format</dt><dd>${pkgLabel(kind)} (${esc(p.format)})</dd><dt>Hardware id</dt><dd>${(p.hw||[]).map(h=>`<span class="tag">${esc(h)}</span>`).join(' ')||'—'}</dd><dt>Size</dt><dd>${p.length?bytes(p.length):'—'}</dd><dt>SHA-256</dt><dd class="mono" style="font-size:12px">${p.hash?esc(p.hash):'—'}</dd>`
    :`<dt>Source</dt><dd>${esc(p.source)} <span class="muted">(delegated)</span></dd>${p.branch?`<dt>Branch / OS</dt><dd>${esc(p.branch)}</dd>`:''}${p.board?`<dt>Board</dt><dd><span class="tag">${esc(p.board)}</span></dd>`:''}${p.variant?`<dt>Variant</dt><dd>${esc(p.variant)}</dd>`:''}<dt>Version</dt><dd class="mono">${esc(p.version||'—')}</dd><dt>Format</dt><dd>${esc(p.format)}</dd><dt>OSTree/URI</dt><dd class="mono" style="font-size:12px">${p.uri?esc(p.uri):'—'}</dd>${p.createdAt?`<dt>Created</dt><dd>${fmtTime(p.createdAt)}</dd>`:''}`;
  document.getElementById('pkgDetail').innerHTML=`
    <a class="back" onclick="go('packages')"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M15 18l-6-6 6-6"/></svg> Packages</a>
    <div class="pdhdr"><span class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">${pkgIcon(p.format,(p.hw||[]).join(' '))}</svg></span>
      <div><h1>${esc(p.name)}</h1><div class="sub"><span class="mono">${esc(p.version||'—')}</span> · <span class="badge ${kind}">${pkgLabel(kind)}</span> · <span class="src">${mine?'My package':esc(p.source)}</span></div></div>
      <div class="dactions"><button class="btn primary" onclick="pkgDeploy()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12M7 10l5 5 5-5M5 21h14"/></svg> Deploy to device</button>${mine?`<button class="btn dbad" onclick="deletePackage()"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2M6 7l1 13h10l1-13"/></svg> Delete</button>`:''}</div></div>
    <div class="card"><header>${H('<circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v4h1"/>')}<h2>Overview</h2></header><dl class="kv" style="padding:16px 18px;margin:0">${meta}</dl></div>
    ${compose!=null?`<div class="card"><header>${H('<path d="M4 7h7v7H4zM13 7h7v4h-7zM13 13h7v4h-7z"/>')}<h2>Compose file</h2></header><pre class="code">${esc(compose)}</pre></div>`:''}
    ${p.sbom?`<div class="card"><header>${H('<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/>')}<h2>Software bill of materials</h2></header><div class="pad" style="padding:16px 18px"><a class="link" href="${esc(p.sbom)}" target="_blank" rel="noopener" style="color:var(--accent);font-weight:600">View SBOM (CycloneDX + VEX) ↗</a> <span class="muted" style="font-size:12px">— may require access; some publishers protect their SBOMs.</span></div></div>`:''}
    ${mine?`<div class="card"><header>${H('<path d="M4 6h16M4 12h16M4 18h10"/>')}<h2>Description</h2><span class="grow"></span><button class="btn sm ghost" onclick="editPkgDescription()">Edit</button></header><div class="pad" style="padding:16px 18px">${p.description?`<div class="md">${md(p.description)}</div>`:'<span class="muted">No description yet. Descriptions live on your own package metadata (Markdown supported); not available for delegated feeds.</span>'}</div></div>`:''}`;
}
async function pkgDeploy(){const p=PKGCUR;if(!p)return;
  const hw=(p.hw||[])[0];if(!hw)return toast('Package has no hardware id.');
  const target=p.source==='mine'?p.key:p.filename;
  if(!p.hash)return toast('Package is missing its checksum.');
  const opts=DEVICES.map(d=>{const set=hwSet(d.uuid);const compat=set.includes(hw);
    return {label:(d.deviceName||d.deviceId),sub:(compat?'has a '+hw+' ECU · compatible':(hwOf(d.uuid)||'unknown hw')+' · no '+hw+' ECU'),uuid:d.uuid,compat:compat,dot:compat?'ok':'warn'};});
  opts.sort((a,b)=>(b.compat?1:0)-(a.compat?1:0));
  if(!opts.length)return toast('No devices provisioned.');
  const idx=await uiPick({title:'Deploy “'+p.name+' '+(p.version||'')+'” to…',options:opts});
  if(idx==null)return;const dev=opts[idx],uuid=dev.uuid;
  // recap: what installs, where, and what's on that ECU today
  const ecu=(INSTALLED[uuid]||[]).find(e=>e.hardwareId===hw);
  const cur=ecu?(imgLabel(ecu)||'nothing yet'):'—';
  const same=ecu&&imgLabel(ecu)===(p.source==='mine'?p.key:(p.filename||'').split('/').pop());
  const kv=(k,v,mono)=>`<dt>${esc(k)}</dt><dd${mono?' class="mono"':''}>${v}</dd>`;
  const body=`<div class="mbody"><dl class="kv recap">
    ${kv('Package','<b>'+esc(p.name)+'</b> '+esc(p.version||''))}
    ${kv('Target ECU','<span class="tag">'+esc(hw)+'</span>')}
    ${kv('Device','<b>'+esc(dev.label)+'</b>')}
    ${kv('Currently on ECU',esc(cur),true)}
    </dl>
    ${!dev.compat?'<div class="rwarn warn"><span class="pk-dot warn"></span>This device has no <b>'+esc(hw)+'</b> ECU — the update won\'t be applied.</div>':same?'<div class="rwarn warn"><span class="pk-dot warn"></span>This version already appears to be installed on that ECU.</div>':'<div class="rwarn ok"><span class="pk-dot ok"></span>The device will download and install on its next check-in.</div>'}</div>`;
  const go2=await uiConfirm({title:'Start this update?',bodyHtml:body,ok:'Install update'});
  if(!go2)return;
  const to={target:target,checksum:{method:'sha256',hash:p.hash},targetLength:p.length||0};if(p.uri)to.uri=p.uri;
  try{const mtu=(await api('/api/director/multi_target_updates',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({targets:{[hw]:{to}}})})).replace(/"/g,'');
    const res=await api('/api/director/assignments',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({correlationId:'urn:here-ota:mtu:'+mtu,mtuId:mtu,devices:[uuid]})});
    toast(res&&res.affected&&res.affected.length?'✓ Update queued — installs on next check-in':'Device not affected (hw mismatch or already installed).');
  }catch(e){toast('Deploy failed: '+e.message);}}
async function deletePackage(){const p=PKGCUR;if(!p||p.source!=='mine')return;
  if(!(await uiConfirm({title:'Delete package?',message:'Permanently delete “'+p.name+' '+(p.version||'')+'” from this cloud. This re-signs your targets metadata and cannot be undone.',ok:'Delete',danger:true})))return;
  try{await api(rapi('targets/'+encodeURIComponent(p.key)),{method:'DELETE'});await loadTargets();toast('Package deleted');go('packages');}catch(e){toast('Delete failed: '+e.message);}}
async function editPkgDescription(){const p=PKGCUR;if(!p||p.source!=='mine')return;
  const v=await uiPrompt({title:'Edit description',label:'Description',value:p.description||'',multiline:true,ok:'Save'});if(v==null)return;
  try{await api(rapi('proprietary-custom/'+encodeURIComponent(p.key)),{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({description:v.trim()})});
    p.description=v.trim();await loadTargets();renderPkgDetail(null);toast('Description saved');}catch(e){toast('Save failed: '+e.message);}}

export { deployPrompt, loadSources, loadTargets, renderPackages };

expose({ addSource, closeEditSource, closeSources, closeUpload, deletePackage, deployPrompt, doUpload, editPkgDescription, editSource, openPackage, openSources, openUpload, pkgDeploy, refreshSource, removeSource, renderPackages, saveSource, setPkgHw, setPkgLayout, setPkgSort, setPkgSource });   // referenced by inline on*= handlers
