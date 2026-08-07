// Entry point: pulls in every view, then boots and schedules the live refreshes.
import { expose, setStatus } from './lib/ui.js';
import { loadDevices } from './views/devices.js';
import { loadTargets, loadSources } from './views/packages.js';
import { loadRaSessions } from './views/remote.js';
import { loadSystem } from './views/system.js';
import { closeProvision } from './views/provision.js';
import './views/device.js';
import './router.js';

async function refreshAll(){try{await Promise.all([loadDevices(),loadTargets(),loadSources()]);setStatus(true);}catch(e){setStatus(false);}}
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeProvision();});

expose({ refreshAll });   // the topbar refresh button

refreshAll();

// live refresh — each tick no-ops unless its view is on screen
setInterval(()=>{if(document.getElementById('v-device').classList.contains('active'))return;loadDevices();},8000);
setInterval(()=>{if(document.getElementById('v-remote').classList.contains('active'))loadRaSessions();},5000);
setInterval(()=>{const v=document.getElementById('v-system');if(v&&v.classList.contains('active'))loadSystem();},5000);
