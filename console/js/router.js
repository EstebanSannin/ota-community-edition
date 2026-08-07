// View switching: toggles .active on nav + sections, sets the page title.
import { expose } from './lib/ui.js';
import { renderPackages } from './views/packages.js';
import { renderRemote } from './views/remote.js';
import { loadSystem, stopLogStream } from './views/system.js';
import { renderLockboxes } from './views/lockbox.js';

const TITLES={dashboard:['Dashboard','Fleet overview'],devices:['Devices','Provisioned devices and their update state'],device:['Device','Device detail'],packages:['Packages','Your packages and the feeds you subscribe to'],package:['Package','Package detail'],remote:['Remote Access','Your SSH key, tunnel duration, and active sessions'],lockbox:['Offline updates','Signed bundles a device can install without network'],system:['System','Services, resources, and live logs on the server']};
function go(v){document.querySelectorAll('.nav a').forEach(a=>a.classList.toggle('active',a.dataset.view===v));
  document.querySelectorAll('.view').forEach(s=>s.classList.toggle('active',s.id==='v-'+v));
  const tt2=TITLES[v]||TITLES.devices;document.getElementById('ptitle').textContent=tt2[0];document.getElementById('psub').textContent=tt2[1];window.scrollTo(0,0);
  if(v==='packages')renderPackages();
  if(v==='remote')renderRemote();
  if(v==='lockbox')renderLockboxes();
  if(v==='system')loadSystem();else stopLogStream();}
document.addEventListener('click',e=>{const a=e.target.closest('[data-view]');if(a){e.preventDefault();go(a.dataset.view);}});
function toggleTheme(){const r=document.documentElement;const cur=r.getAttribute('data-theme')||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');r.setAttribute('data-theme',cur==='dark'?'light':'dark');}

export { go };

expose({ go, toggleTheme });   // referenced by inline on*= handlers
