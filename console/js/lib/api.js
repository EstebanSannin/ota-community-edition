// Backend access + formatting helpers. Every call is same-origin; nginx proxies the prefixes.
const api=(p,o)=>fetch(p,o).then(async r=>{if(!r.ok)throw new Error((await r.text())||r.status);const t=await r.text();if(!t)return null;try{return JSON.parse(t);}catch(e){return t;}});
const rapi=p=>'/api/reposerver/user_repo/'+p;
const dapi=p=>'/api/device-registry/'+p;
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtTime=t=>t?new Date(t).toLocaleString():'—';
const relTime=t=>{if(!t)return'—';let s=(Date.now()-new Date(t))/1000;const fut=s<0;s=Math.abs(s);
  if(s<45)return'just now';
  let v;if(s<3600)v=Math.floor(s/60)+' min';else if(s<86400)v=Math.floor(s/3600)+' h';else v=Math.floor(s/86400)+' d';
  return fut?('in '+v):(v+' ago');};
const shortHash=h=>h?h.slice(0,12):'';
const bytes=n=>{n=+n;if(!n||n<0)return null;const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++;}return (n>=100?Math.round(n):n.toFixed(1))+' '+u[i];};

export { api, bytes, dapi, esc, fmtTime, rapi, relTime, shortHash };
