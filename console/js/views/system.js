// System page: service status, host + machine metrics, live logs.
import { expose } from '../lib/ui.js';
import { api, esc } from '../lib/api.js';

// ---------- System page (ops sidecar: status + resources + live logs) ----------
let _logES=null, _sysLast=null;
function fmtMB(mb){return mb>=1024?(mb/1024).toFixed(1)+' GB':(mb||0)+' MB';}
function fmtBps(b){b=b||0;const u=['B','KB','MB','GB'];let i=0;while(b>=1024&&i<u.length-1){b/=1024;i++;}return (i?b.toFixed(1):Math.round(b))+' '+u[i]+'/s';}
function fmtUptime(s){const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?d+'d '+h+'h':(h?h+'h '+m+'m':m+'m');}
function setSysSpin(on,txt){const s=document.getElementById('sys-spin'),u=document.getElementById('sys-updated');if(s)s.classList.toggle('hide',!on);if(u&&txt!==undefined)u.textContent=txt;}
function renderSystem(d){
  const t=d.totals||{},dk=d.disk||{},dd=d.docker_disk||{},h=d.host||{},m=d.machine||{};
  document.getElementById('sys-svc').textContent=(t.up||0)+' / '+(t.total||0);
  document.getElementById('sys-cpu').textContent=(t.cpu||0)+'%';
  document.getElementById('sys-mem').textContent=fmtMB(t.mem_used_mb)+' / '+fmtMB(t.mem_total_mb);
  document.getElementById('sys-disk').textContent=fmtMB(dk.free_mb)+' free';
  document.getElementById('sys-disk-sub').textContent=fmtMB(dk.used_mb)+' used of '+fmtMB(dk.total_mb)+' ('+(dk.pct||0)+'%)';
  document.getElementById('sys-host-name').textContent=h.hostname||'';
  const hrows=[['Operating system',h.os],['Kernel',h.kernel],['Architecture',h.arch],['CPUs',h.cpus],
    ['Total memory',fmtMB(t.mem_total_mb)],['Docker',h.docker],
    ['Disk',fmtMB(dk.used_mb)+' / '+fmtMB(dk.total_mb)+' ('+(dk.pct||0)+'%) · '+fmtMB(dk.free_mb)+' free'],
    ['Docker usage','images '+fmtMB(dd.images_mb)+' · volumes '+fmtMB(dd.volumes_mb)+' · cache '+fmtMB(dd.build_cache_mb)]];
  document.getElementById('sys-host').innerHTML=hrows.filter(r=>r[1]!==undefined&&r[1]!=='').map(r=>
    '<div class="hr"><span class="hk">'+esc(r[0])+'</span><span class="hv">'+esc(String(r[1]))+'</span></div>').join('');
  document.getElementById('sys-load').textContent=(m.load&&m.load.length)?m.load.map(x=>x.toFixed(2)).join('  '):'—';
  document.getElementById('sys-uptime').textContent=m.uptime_secs?fmtUptime(m.uptime_secs):'—';
  document.getElementById('sys-net').innerHTML=(m.net&&m.net.length)?m.net.map(n=>esc(n.iface)+' ↓'+fmtBps(n.rx_bps)+' ↑'+fmtBps(n.tx_bps)).join('&nbsp;&nbsp;'):'—';
  const cores=m.cores||[];
  document.getElementById('sys-cores').innerHTML=cores.length?'<span class="cores">'+cores.map(c=>'<span class="core" title="core '+c.core+': '+c.pct+'%"><i style="height:'+Math.max(3,Math.min(100,c.pct))+'%"></i></span>').join('')+'</span>':'—';
  const rows=d.services||[];
  document.getElementById('sys-services').innerHTML='<table><thead><tr><th>Service</th><th>State</th><th class="right">CPU</th><th class="right">Memory</th><th>Status</th></tr></thead><tbody>'+
    rows.map(r=>{const ok=r.state==='running';
      const dot='<span style="display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:8px;background:'+(ok?'var(--ok)':'var(--bad)')+'"></span>';
      return '<tr><td>'+dot+esc(r.service)+'</td><td class="'+(ok?'':'muted')+'">'+esc(r.state)+'</td><td class="mono right">'+(r.cpu||0)+'%</td><td class="mono right">'+fmtMB(r.mem_mb)+'</td><td class="muted">'+esc(r.status||'')+'</td></tr>';
    }).join('')+'</tbody></table>';
  const pick=document.getElementById('sys-log-pick'),cur=pick.value;
  pick.innerHTML='<option value="">Select a service…</option>'+rows.map(r=>'<option value="'+esc(r.name)+'">'+esc(r.service)+'</option>').join('');
  if(cur&&rows.some(r=>r.name===cur))pick.value=cur;
}
async function loadSystem(){
  if(!_sysLast){try{_sysLast=JSON.parse(localStorage.getItem('ops:last')||'null');}catch(e){}}
  const first=!_sysLast;
  if(_sysLast)renderSystem(_sysLast);                 // instant paint from last-known data
  if(first)setSysSpin(true,'loading…');
  let d;
  try{ d=await api('/api/ops/status'); }
  catch(e){ if(first)document.getElementById('sys-services').innerHTML='<div class="empty">Ops service not reachable — deploy the observability overlay (<span class="mono">compose.observability.yaml</span>).</div>'; setSysSpin(false,'offline'); return; }
  if(d&&d.warming){ setSysSpin(true,'warming up…'); return; }
  if(d&&d.error){ if(first)document.getElementById('sys-services').innerHTML='<div class="empty">Docker unreachable from ops: '+esc(d.error)+'</div>'; setSysSpin(false,'error'); return; }
  _sysLast=d; try{localStorage.setItem('ops:last',JSON.stringify(d));}catch(e){}
  renderSystem(d); setSysSpin(false,'updated just now');
}
function stopLogStream(){ if(_logES){_logES.close();_logES=null;} }
function startLogStream(name){
  stopLogStream();
  const pane=document.getElementById('sys-logpane'),status=document.getElementById('sys-log-status');
  if(!name){pane.innerHTML='<div class="empty">Pick a service to stream its logs.</div>';status.textContent='—';status.className='termstatus';return;}
  pane.innerHTML=''; status.textContent='connecting…'; status.className='termstatus';
  const es=new EventSource('/api/ops/logs?name='+encodeURIComponent(name)+'&tail=300'); _logES=es;
  es.onopen=()=>{status.textContent='streaming';status.className='termstatus ok';};
  es.onmessage=(e)=>{
    const atBottom=pane.scrollHeight-pane.scrollTop-pane.clientHeight<40;
    const line=document.createElement('div'); line.className='ll';
    const m=e.data.match(/^(\S+)\s([\s\S]*)$/);
    if(m&&/\dT\d/.test(m[1]))line.innerHTML='<span class="lt">'+esc(m[1].replace('T',' ').replace(/\..*$/,''))+'</span>'+esc(m[2]);
    else line.textContent=e.data;
    pane.appendChild(line);
    while(pane.childElementCount>2000)pane.removeChild(pane.firstChild);
    if(atBottom)pane.scrollTop=pane.scrollHeight;
  };
  es.onerror=()=>{status.textContent='disconnected';status.className='termstatus bad';};
}

export { loadSystem, stopLogStream };

expose({ loadSystem, startLogStream });   // referenced by inline on*= handlers
