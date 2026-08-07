// Styled in-app replacements for window.prompt / confirm / a picker.
function uiPrompt(o){o=o||{};return new Promise(resolve=>{
  const ov=document.createElement('div');ov.className='modal open';const multi=!!o.multiline;
  ov.innerHTML=`<div class="m mini"><header><h3></h3></header>
    <div class="mbody">${o.label?'<span class="ml"></span>':''}${multi?'<textarea class="mf" rows="3"></textarea>':'<input class="mf" type="text">'}</div>
    <footer><button class="btn mcancel">Cancel</button><button class="btn primary mok"></button></footer></div>`;
  ov.querySelector('h3').textContent=o.title||'';if(o.label)ov.querySelector('.ml').textContent=o.label;
  ov.querySelector('.mok').textContent=o.ok||'OK';
  const f=ov.querySelector('.mf');f.value=o.value||'';if(o.placeholder)f.placeholder=o.placeholder;
  function close(v){document.removeEventListener('keydown',onKey);ov.remove();resolve(v);}
  function onKey(e){if(e.key==='Escape')close(null);else if(e.key==='Enter'&&!multi){e.preventDefault();close(f.value);}}
  ov.querySelector('.mcancel').onclick=()=>close(null);ov.querySelector('.mok').onclick=()=>close(f.value);
  ov.addEventListener('mousedown',e=>{if(e.target===ov)close(null);});document.addEventListener('keydown',onKey);
  document.body.appendChild(ov);f.focus();if(f.select)f.select();});}
function uiConfirm(o){o=o||{};return new Promise(resolve=>{
  const ov=document.createElement('div');ov.className='modal open';
  ov.innerHTML=`<div class="m mini"><header><h3></h3></header>
    <div class="mbody"><p class="mmsg"></p></div>
    <footer><button class="btn mcancel">Cancel</button><button class="btn mok"></button></footer></div>`;
  ov.querySelector('h3').textContent=o.title||'Confirm';
  if(o.bodyHtml)ov.querySelector('.mmsg').outerHTML=o.bodyHtml;else ov.querySelector('.mmsg').textContent=o.message||'';
  const ok=ov.querySelector('.mok');ok.textContent=o.ok||'OK';ok.classList.add(o.danger?'dbad':'primary');
  function close(v){document.removeEventListener('keydown',onKey);ov.remove();resolve(v);}
  function onKey(e){if(e.key==='Escape')close(false);else if(e.key==='Enter')close(true);}
  ov.querySelector('.mcancel').onclick=()=>close(false);ok.onclick=()=>close(true);
  ov.addEventListener('mousedown',e=>{if(e.target===ov)close(false);});document.addEventListener('keydown',onKey);
  document.body.appendChild(ov);ok.focus();});}
function uiPick(o){o=o||{};return new Promise(resolve=>{
  const ov=document.createElement('div');ov.className='modal open';
  ov.innerHTML=`<div class="m"><header><h3></h3></header><div class="mbody picklist"></div><footer><button class="btn mcancel">Cancel</button></footer></div>`;
  ov.querySelector('h3').textContent=o.title||'Choose';const list=ov.querySelector('.picklist');
  (o.options||[]).forEach((op,i)=>{const b=document.createElement('button');b.className='pickrow';
    const top=document.createElement('span');top.className='pk-top';
    if(op.dot){const d=document.createElement('span');d.className='pk-dot '+op.dot;top.appendChild(d);}
    const t=document.createElement('span');t.className='pk-t';t.textContent=op.label;top.appendChild(t);b.appendChild(top);
    if(op.sub){const s=document.createElement('span');s.className='pk-s';s.textContent=op.sub;b.appendChild(s);}
    b.onclick=()=>close(i);list.appendChild(b);});
  function close(v){document.removeEventListener('keydown',onKey);ov.remove();resolve(v);}
  function onKey(e){if(e.key==='Escape')close(null);}
  ov.querySelector('.mcancel').onclick=()=>close(null);
  ov.addEventListener('mousedown',e=>{if(e.target===ov)close(null);});document.addEventListener('keydown',onKey);
  document.body.appendChild(ov);});}

export { uiConfirm, uiPick, uiPrompt };
