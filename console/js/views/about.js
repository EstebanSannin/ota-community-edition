// "About" dialog: project identity + the deployed instance version. Opened from the left rail.
// Version comes from ota-lith's build-time BuildInfo (git commit + build time) via /api/version.
import { esc } from '../lib/api.js';
import { expose } from '../lib/ui.js';

async function openAbout(){
  const ov = document.createElement('div'); ov.className = 'modal open';
  ov.innerHTML = `<div class="m"><header><h3>About</h3></header>
    <div class="form" style="padding:18px 20px;gap:14px">
      <div>
        <div style="font-size:16px;font-weight:600">OTA Community Edition</div>
        <div class="muted" style="font-size:13px;margin-top:2px">Self-hostable OTA cloud for Torizon OS devices — built on TUF / Uptane.</div>
      </div>
      <div class="hostgrid" id="about-rows">
        <div class="hr"><span class="hk">Instance</span><span class="hv mono">${esc(location.host)}</span></div>
        <div class="hr"><span class="hk">Version</span><span class="hv mono" id="about-ver">…</span></div>
        <div class="hr"><span class="hk">Built</span><span class="hv" id="about-built">…</span></div>
        <div class="hr"><span class="hk">Core</span><span class="hv" id="about-core">ota-lith · reposerver · keyserver · director · treehub</span></div>
      </div>
      <div class="muted" style="font-size:12px">The four Uptane services run as a single <span class="mono">ota-lith</span> process, so they share one build. Sidecars (provisioner, lockbox, ops, auth, ras) are deployed alongside it.</div>
    </div>
    <footer><button class="btn mcancel">Close</button><span class="grow"></span>
      <a class="btn" href="apidocs/" target="_blank" rel="noopener">API reference</a></footer></div>`;
  document.body.appendChild(ov);
  const close = () => ov.remove();
  ov.querySelector('.mcancel').onclick = close;
  ov.addEventListener('mousedown', e => { if(e.target === ov) close(); });

  // Fill in the version from the running instance (blank/unknown if unavailable).
  try {
    const v = await (await fetch('/api/version', {headers:{'Accept':'application/json'}})).json();
    const ver = ov.querySelector('#about-ver'); if(ver) ver.textContent = (v.version || 'unknown').slice(0, 12);
    const built = ov.querySelector('#about-built'); if(built) built.textContent = (v.builtAtString || '').slice(0, 19) || '—';
    const core = ov.querySelector('#about-core');
    if(core && v.scalaVersion) core.textContent = `ota-lith · Scala ${v.scalaVersion} · sbt ${v.sbtVersion || '?'}`;
    if(ver) ver.title = 'ota-lith ' + (v.version || '');
  } catch(e){
    const ver = ov.querySelector('#about-ver'); if(ver) ver.textContent = 'unavailable';
    const built = ov.querySelector('#about-built'); if(built) built.textContent = '—';
  }
}

export { openAbout };

expose({ openAbout });   // referenced by the inline onclick in the rail
