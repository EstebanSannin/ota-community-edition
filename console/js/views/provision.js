// Provisioning dialog: token minting and the device one-liner.
import { api } from '../lib/api.js';
import { expose, showMsg } from '../lib/ui.js';

// ---------- provisioning ----------
function openProvision(){document.getElementById('provModal').classList.add('open');renderProvCmd();generateProvToken();}
async function generateProvToken(){
  const tf=document.getElementById('provToken'),note=document.getElementById('provTokNote'),btn=document.getElementById('provGenBtn');
  if(btn)btn.disabled=true; if(note)note.textContent='· generating…';
  try{
    const r=await api('/api/provision-tokens',{method:'POST'});
    const o=(typeof r==='object'&&r)?r:JSON.parse(r);
    tf.value=o.token||''; renderProvCmd();
    if(note)note.textContent=o.ttl_secs?('· short-lived, expires in '+Math.max(1,Math.round(o.ttl_secs/60))+' min'):'';
  }catch(e){ if(note)note.textContent='· couldn’t generate (open provisioning, or service unavailable)'; }
  finally{ if(btn)btn.disabled=false; }
}
function closeProvision(){document.getElementById('provModal').classList.remove('open');}
function renderProvCmd(){const name=(document.getElementById('provName').value||'').trim().replace(/[^A-Za-z0-9_-]/g,'');const tok=(document.getElementById('provToken').value||'').trim();const rep=document.getElementById('provReporter')?.checked?' -r':'';const rem=document.getElementById('provRemote')?.checked?' -a':'';const o=location.origin,n=name?(' -n '+name):'',t=tok?(' -t '+tok):'';document.getElementById('provCmd').value=`curl -fsSL ${o}/provision-device.sh | sudo bash -s -- -s ${o}${n}${t}${rep}${rem}`;}
function copyProvCmd(){const t=document.getElementById('provCmd');navigator.clipboard.writeText(t.value).then(()=>showMsg(document.getElementById('provMsg'),'ok','Copied — paste into a root shell on the device.')).catch(()=>{t.select();document.execCommand('copy');});}

export { closeProvision };

expose({ closeProvision, copyProvCmd, generateProvToken, openProvision, renderProvCmd });   // referenced by inline on*= handlers
