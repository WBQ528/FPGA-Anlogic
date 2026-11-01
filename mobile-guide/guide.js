'use strict';
const $=id=>document.getElementById(id);
// The route is supplied by the FPGA's runtime QR payload, never inferred from
// an image, a server-generated QR or a fixed pre-rendered itinerary.
function readRoute(search){const raw=new URLSearchParams(search).get('r');return raw&&/^[1-4]{1,4}$/.test(raw)&&new Set(raw).size===raw.length?[...raw].map(Number):null;}
const suppliedRoute=readRoute(location.search), route=suppliedRoute||[1,2,4,3];
const storageKey='bq-garden-walk:'+route.join('');
let visited=new Set(),gardens=[],current=route[0],data;
try{const saved=JSON.parse(localStorage.getItem(storageKey)||'[]');if(Array.isArray(saved))visited=new Set(saved.filter(v=>route.includes(v)));}catch{}
function saveVisited(){try{localStorage.setItem(storageKey,JSON.stringify([...visited]));}catch{}}
function el(tag,attrs={},text){const n=document.createElement(tag);for(const[k,v]of Object.entries(attrs))n.setAttribute(k,v);if(text!==undefined)n.textContent=text;return n;}
function garden(id){return gardens.find(g=>g.id===id);}
function renderRoute(){
 $('route-count').textContent=route.length+' 个园区';$('route-title').textContent=suppliedRoute?'我的游览清单':'四园推荐游览';
 $('route-note').textContent=suppliedRoute?'已带上屏幕中选定的顺序。点开一站，慢慢发现它的故事。':'从四园风景开始认识植物园。您也可以扫码带上自己选定的游览顺序。';
 $('itinerary').replaceChildren(...route.map((id,i)=>{const g=garden(id),li=el('li',{class:visited.has(id)?'done':''});
 const a=el('a',{href:'#garden-title','aria-label':`第${i+1}站 ${g.name}，查看介绍`});a.append(el('img',{src:g.images[0].src,alt:g.images[0].alt,loading:'lazy'}),el('span',{class:'number'},visited.has(id)?'✓':String(i+1)),el('strong',{},g.name),el('small',{},visited.has(id)?'已经走过 · 再看一眼':g.tag));a.onclick=()=>showGarden(id);li.append(a);return li;}));
 $('progress-label').textContent=visited.size?`已游览 ${visited.size} / ${route.length} 园`:'准备出发';$('walk-progress').max=route.length;$('walk-progress').value=visited.size;
}
function renderMap(){const ns='http://www.w3.org/2000/svg',svg=$('map-route');svg.replaceChildren();
 const points=route.map(id=>{const g=garden(id);return `${g.x},${g.y}`;}).join(' ');
 for(const[color,width]of [['#fffdf7',17],['#bb2636',10]]){const line=document.createElementNS(ns,'polyline');Object.entries({points,fill:'none',stroke:color,'stroke-width':width,'stroke-linecap':'round','stroke-linejoin':'round'}).forEach(([k,v])=>line.setAttribute(k,v));svg.append(line);}
 route.forEach((id,i)=>{const g=garden(id),a=document.createElementNS(ns,'a');a.setAttribute('href','#garden-title');a.setAttribute('aria-label',`第${i+1}站 ${g.name}`);a.onclick=()=>showGarden(id);const circle=document.createElementNS(ns,'circle');Object.entries({cx:g.x,cy:g.y,r:26,fill:'#bb2636',stroke:'#fffdf7','stroke-width':7}).forEach(([k,v])=>circle.setAttribute(k,v));const t=document.createElementNS(ns,'text');Object.entries({x:g.x,y:g.y+10,'text-anchor':'middle',fill:'#fff','font-size':30,'font-family':'system-ui','font-weight':700}).forEach(([k,v])=>t.setAttribute(k,v));t.textContent=String(i+1);a.append(circle,t);svg.append(a);});
}
function showGarden(id){current=id;const g=garden(id),article=$('garden-detail');article.replaceChildren();
 for(const b of $('garden-tabs').children)b.setAttribute('aria-pressed',String(+b.dataset.id===id));
 const head=el('div',{class:'detail-header'}),title=el('div');title.append(el('p',{class:'tag'},g.tag),el('h3',{},g.fullName),el('p',{class:'position'},g.position));head.append(title);
 if(route.includes(id)){const b=el('button',{type:'button',class:'visit-toggle','aria-pressed':String(visited.has(id))},visited.has(id)?'✓ 已游览':'标记已游览');b.onclick=()=>{visited.has(id)?visited.delete(id):visited.add(id);saveVisited();renderRoute();showGarden(id);};head.append(b);}article.append(head);
 const gallery=el('div',{class:'gallery'});for(const p of g.images){const b=el('button',{type:'button','aria-label':'放大查看：'+p.alt});b.append(el('img',{src:p.src,alt:p.alt,loading:'lazy'}));b.onclick=()=>{$('large-photo').src=p.src;$('large-photo').alt=p.alt;$('large-caption').textContent=p.alt;$('photo-dialog').showModal();};gallery.append(b);}article.append(gallery,el('p',{class:'image-note'},'轻触照片可查看完整大图 · 照片记录不同季节的风景'),el('p',{class:'intro'},g.intro));
 const stats=el('div',{class:'stats'});g.stats.forEach(([n,k])=>{const d=el('div');d.append(el('strong',{},n),el('span',{},k));stats.append(d);});article.append(stats,el('p',{class:'stats-note'},g.note),el('h4',{class:'detail-subtitle'},'在这里，可以认识'));
 const plants=el('div',{class:'plants'});g.plants.forEach(p=>plants.append(el('span',{},p)));article.append(plants,el('h4',{class:'detail-subtitle'},'停下来，看一看'));
 const tips=el('ol',{class:'observe'});g.observe.forEach(p=>tips.append(el('li',{},p)));article.append(tips,el('a',{class:'source-link',href:g.source,target:'_blank',rel:'noopener'},`资料：成都市植物园 · ${g.date} ↗`));
 const at=route.indexOf(id);let next=at>=0&&at<route.length-1?route[at+1]:null;const nav=el('button',{class:'next-stop',type:'button'}),words=el('span');
 words.append(el('small',{},next?'按您的游览顺序':'把四园的位置记在心里'),el('strong',{},next?`下一站 · ${garden(next).name}`:'回到园区地图'));nav.append(words,el('span',{'aria-hidden':'true'},'→'));nav.onclick=()=>{if(next){showGarden(next);$('garden-title').scrollIntoView();}else $('map').scrollIntoView();};article.append(nav);
}
function renderCredits(){const box=$('credits');gardens.forEach(g=>{const p=el('p');p.append(el('a',{href:g.source,target:'_blank',rel:'noopener'},`${g.fullName}资料 · 园方官网 ${g.date}`));box.append(p);});data.assets.forEach(a=>{const p=el('p');p.append(document.createTextNode(`${a.garden} · ${a.author}`));if(a.url)p.append(document.createTextNode(' · '),el('a',{href:a.url,target:'_blank',rel:'noopener'},'原始出处'));box.append(p);});}
$('copy-link').onclick=async()=>{const url=new URL(location.href);url.hash='';url.search='?r='+route.join('');try{await navigator.clipboard.writeText(url.href);$('copy-status').textContent='已复制，可分享或收藏';}catch{$('copy-status').textContent='可通过浏览器菜单分享当前页面';}};
$('expand-map').onclick=()=>{const clone=$('map-frame').cloneNode(true);clone.removeAttribute('id');clone.querySelector('svg').removeAttribute('id');$('large-map').replaceChildren(clone);$('map-dialog').showModal();};
document.querySelectorAll('dialog').forEach(d=>d.querySelector('.dialog-close').onclick=()=>d.close());
fetch('guide-data.json').then(r=>{if(!r.ok)throw Error('data');return r.json();}).then(d=>{data=d;gardens=d.gardens;for(const g of gardens){const b=el('button',{type:'button','data-id':g.id,'aria-pressed':'false'},g.name);b.onclick=()=>showGarden(g.id);$('garden-tabs').append(b);}renderRoute();renderMap();showGarden(current);renderCredits();}).catch(()=>{$('route-note').textContent='导览资料暂时未能加载，请检查网络后刷新。';$('route-note').classList.add('error');});
