// Chrome-level UI helpers: toast, inline messages, connection dot, status pills.
let tt;function toast(m){const t=document.getElementById('toast');t.textContent=m;t.classList.add('show');clearTimeout(tt);tt=setTimeout(()=>t.classList.remove('show'),2600);}
function showMsg(el,cls,txt){if(el){el.className='msg show '+cls;el.textContent=txt;}}
function setStatus(up){document.getElementById('dot').className='dot '+(up?'up':'down');document.getElementById('status').textContent=up?('connected · '+location.host):'backend unreachable';}
function pillClass(s){return s==='UpToDate'?'ok':(s==='Outdated'||s==='UpdatePending'||s==='UpdateScheduled')?'warn':(s==='Error')?'bad':'idle';}

const avatar='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="4" y="4" width="16" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></svg>';

// Inline on*= handlers in the markup are evaluated in global scope, which module scope is not.
// Each module calls expose() with the handlers its markup references. Removing an expose() entry
// is the last step of migrating that view to addEventListener.
export const expose = obj => Object.assign(window, obj);

export { avatar, pillClass, setStatus, showMsg, toast };

expose({ toast });   // referenced by inline on*= handlers
