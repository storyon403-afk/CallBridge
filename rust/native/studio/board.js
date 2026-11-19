// 页面只保留导航、筛选和焦点。设备、权限、播放以及组合选择都以宿主返回的快照为准。
'use strict';
const groups={all:'全部',voice:'音色',actor:'形象',scene:'画面背景',track:'背景音'};
const scenes=[
  ['coast-evening.jpg','落日海岸','coast'],['window-morning.jpg','窗边晨光','window'],
  ['original','现场背景'],['sample','流光 · 视频素材'],['parallax','窗景 · 2.5D'],['plate','采集静态背景']
];
const modes=[['avatar','形象','avatar'],['real','真人','real'],['none','纯背景','landscape']];
let category='all', inspector='';
let displayedCategory, cardLayout;
const pluginArt=id=>'cb-art://plugin/'+encodeURIComponent(id);
function view(tab) {
  for(const [key,section,button] of [['mix','mix-board','mix-view'],['route','bay','route-view']]){
    byId(section).hidden=tab!==key;
    byId(button).setAttribute('aria-pressed',String(tab===key));
  }
}
function openInspector(key) {
  inspector=inspector===key?'':key;draw();
}
function materials() {
  const items=[];
  const add=(kind,id,name,art,selected,enabled=true,pluginKind='')=>items.push({kind,id,name,art,selected,enabled,pluginKind});
  for(const [id,name,art] of scenes)add('scene',id,name,art,state.scene===id,true);
  add('actor','cheng','澄 · 通话装','cheng',state.mode==='avatar'&&state.actor==='cheng',true);
  for(const p of state.assets){
    if(p.kind==='avatar')add('actor',p.id,p.name,null,state.mode==='avatar'&&state.actor===p.id,true,p.kind);
    if(p.kind.startsWith('background-'))add('scene',p.id,p.name,null,state.scene===p.id,true,p.kind);
    if(p.kind==='audio-background')add('track',p.id,p.name,'ambience',p.selected,state.importOK);
  }
  if(state.fileID&&!items.some(i=>i.kind==='track'&&i.selected))add('track','current',state.file,'ambience',true);
  for(const v of state.voice.items)add('voice',v.id,v.name,'voice',v.id===state.voice.selected,state.voice.enabled);
  const assets=new Map(state.assets.map(p=>[p.id,p]));
  for(const item of items)item.plugin=assets.get(item.id);
  return items;
}
async function mediaBlob(plugin,signal){
  const chunks=[];
  let offset=0,total;
  do {
    signal?.throwIfAborted();
    const part=await window.webkit.messageHandlers.studio.postMessage({
      action:'assetChunk',value:plugin.id,version:plugin.version||'',offset
    });
    signal?.throwIfAborted();
    const bytes=Uint8Array.fromBase64 ? Uint8Array.fromBase64(part.data) : Uint8Array.from(atob(part.data),c=>c.charCodeAt(0));
    if(!bytes.length || (total!==undefined && total!==part.total))throw Error('Media changed');
    chunks.push(bytes);offset+=bytes.length;total=part.total;
  } while(offset<total);
  const mime={mp4:'video/mp4',mov:'video/quicktime',webm:'video/webm'};
  return new Blob(chunks,{type:mime[plugin.format]||'application/octet-stream'});
}
const portraits=new Map();
let renderQueue=Promise.resolve();
function portraitSource(plugin){
  if(!plugin)return Promise.resolve('media/cheng.png');
  if(plugin.format!=='vrm')return Promise.resolve(pluginArt(plugin.id)+'?v='+encodeURIComponent(plugin.version||''));
  const key=JSON.stringify([plugin.id,plugin.version]);
  if(!portraits.has(key)){
    const result=renderQueue.then(async()=>window.renderStudioPortrait(await (await mediaBlob(plugin)).arrayBuffer()));
    renderQueue=result.catch(()=>{portraits.delete(key);});
    portraits.set(key,result);
  }
  return portraits.get(key);
}
const portraitObserver=new IntersectionObserver(entries=>{
  for(const {target,isIntersecting} of entries)if(isIntersecting){
    portraitObserver.unobserve(target);
    portraitSource(target.asset).then(src=>{if(target.isConnected)target.src=src;}).catch(()=>target.remove());
  }
});
let actorKey,sceneKey,sceneAbort,movieURL;
const previewNotes={actor:'',scene:''};
function previewNote(slot,value){
  previewNotes[slot]=value;
  byId('preview-status').textContent=Object.values(previewNotes).filter(Boolean).map(tr).join(' · ');
}
function showActor(actor){
  const key=JSON.stringify([state.mode,state.actor,actor?.version]);
  if(actorKey===key)return;
  actorKey=key;
  const portrait=byId('portrait');
  portrait.hidden=true;portrait.removeAttribute('src');
  previewNote('actor','');
  if(state.mode!=='avatar')return;
  previewNote('actor','正在载入人物');
  portrait.onload=()=>{if(actorKey===key){portrait.hidden=false;previewNote('actor','');}};
  portrait.onerror=()=>{if(actorKey===key){portrait.hidden=true;previewNote('actor','人物预览不可用');}};
  portraitSource(actor).then(src=>{if(actorKey===key)portrait.src=src;})
    .catch(()=>{if(actorKey===key)previewNote('actor','人物预览不可用');});
}
function showScene(plugin,image){
  const key=JSON.stringify([state.scene,plugin?.version,image]);
  if(sceneKey===key)return;
  sceneKey=key;sceneAbort?.abort();sceneAbort=new AbortController();
  const bg=byId('backdrop'),movie=byId('motion-backdrop');
  movie.onloadeddata=null;movie.onerror=null;movie.pause();movie.removeAttribute('src');movie.load();movie.hidden=true;
  if(movieURL){URL.revokeObjectURL(movieURL);movieURL=null;}
  bg.hidden=!image;if(image)bg.src=image;else bg.removeAttribute('src');
  previewNote('scene','');
  if(state.scene!=='sample'&&plugin?.kind!=='background-video')return;
  previewNote('scene','正在载入循环背景');
  const start=src=>{
    if(image)movie.poster=image;else movie.removeAttribute('poster');
    movie.hidden=false;movie.muted=true;movie.src=src;
    movie.onloadeddata=()=>{if(sceneKey===key){movie.hidden=false;previewNote('scene','');}};
    movie.onerror=()=>{if(sceneKey===key){movie.hidden=true;previewNote('scene','视频预览不可用');}};
    movie.play().catch(()=>{if(sceneKey===key)previewNote('scene','视频预览不可用');});
  };
  if(state.scene==='sample'){start('media/aurora.mp4');return;}
  mediaBlob(plugin,sceneAbort.signal).then(blob=>{
    if(sceneKey===key){movieURL=URL.createObjectURL(blob);start(movieURL);}
  }).catch(()=>{if(sceneKey===key)previewNote('scene','视频预览不可用');});
}
function makeCard(item){
  const currentFile=item.kind==='track'&&item.id==='current';
  const card=control('',currentFile?'inspect':item.kind,currentFile?'track':item.id);
  card.className='card';
  const title=element('strong',item.name);
  card.title=title.textContent;
  const caption=element('div','','card-caption');
  const type=item.pluginKind==='background-video'?'视频':groups[item.kind];
  caption.append(title,element('small',type));
  const art=element('span',item.art?'':type,'art '+(item.art||'generic'));
  art.setAttribute('aria-hidden','true');
  if(['avatar','background-image','background-video'].includes(item.pluginKind)){
    if(item.kind==='actor')art.classList.add('actor-portrait');
    const image=element('img');
    image.onload=()=>art.classList.add('decoded');
    image.alt='';image.loading='lazy';image.decoding='async';
    if(item.plugin.format==='vrm'){image.asset=item.plugin;portraitObserver.observe(image);}
    else image.src=pluginArt(item.id)+'?tile';
    image.onerror=()=>image.remove();
    art.append(image);
  }
  card.append(art,caption);
  return card;
}
function drawCards(items){
  const list=byId('cards');
  const visible=category==='all'?items:items.filter(item=>item.kind===category);
  // 分类和素材内容决定卡片结构；播放进度、音量和选中态只改已有节点。
  const layout=JSON.stringify(visible.map(i=>[i.kind,i.id,i.name,i.art,i.pluginKind,i.plugin?.version]));
  if(displayedCategory!==category || layout!==cardLayout){
    const position=displayedCategory===category?list.scrollTop:0;
    list.querySelectorAll("img").forEach(img=>portraitObserver.unobserve(img));
    list.replaceChildren(...visible.map(makeCard));
    if(category==='track')list.append(control('导入背景音','wav'));
    list.scrollTop=position;
    displayedCategory=category;cardLayout=layout;
  }
  visible.forEach((item,index)=>{
    const card=list.children[index],pressed=String(Boolean(item.selected));
    if(card.getAttribute('aria-pressed')!==pressed)card.setAttribute('aria-pressed',pressed);
    if(card.disabled===Boolean(item.enabled))card.disabled=!item.enabled;
  });
  if(category==='track')list.lastElementChild.disabled=!state.importOK;
}
function draw(){
  if(!state)return;
  const speech=byId('open-speech');
  speech.textContent=tr(state.speechVisible?'关闭打字说话':'打字说话');
  speech.dataset.action=state.speechVisible?'closeText':'text';
  speech.setAttribute('aria-expanded',String(Boolean(state.speechVisible)));
  view(state.tab||'mix');
  const focus=document.activeElement;
  const key=focus.dataset?.action, val=focus.dataset?.value;
  const owner=focus.closest('#cards,#slots,#framing,#inspector,#lanes,#mic-tools,#filters');
  const items=materials();
  const name=k=>items.find(i=>i.kind===k&&i.selected)?.name;
  const visibleScene=name('scene')||state.scene;
  const bg=byId('backdrop');
  const photo=scenes.find(s=>s[0]===state.scene&&s[2]);
  const selectedScene=state.assets.find(p=>p.id===state.scene);
  const actor=state.assets.find(p=>p.id===state.actor);
  const image=photo?'media/'+photo[0]:selectedScene?.kind.startsWith('background-')?pluginArt(state.scene)+'?v='+encodeURIComponent(selectedScene.version||''):null;
  showScene(selectedScene,image);
  showActor(actor);
  bg.parentElement.dataset.framing=state.mode;
  byId('scene-name').textContent=tr(visibleScene);
  byId('scene-note').textContent=state.mode==='avatar'?tr(name('actor')||'形象'):tr(state.mode==='real'?'真人 · 构图示意':'纯背景');
  byId('route-state').textContent=state.status;byId('route-info').textContent=state.route;
  byId('global-stop').disabled=!state.stopOK;
  byId('import').disabled=!state.importOK;
  byId('refresh').disabled=!state.refreshOK;
  byId('glass').setAttribute('aria-pressed',String(state.glass));
  document.body.classList.toggle('solid',!state.glass);
  byId('framing').replaceChildren(element('span','取景','frame-title'),...modes.map(([id,text,cls])=>{
    const b=control(text,'mode',id,true,id===state.mode), pic=element('span','','frame-pic '+cls);
    if(id==='avatar'){
      const img=element('img');img.alt='';pic.append(img);
      portraitSource(actor).then(src=>{if(pic.isConnected)img.src=src;}).catch(()=>img.remove());
    }
    if(id==='real')pic.append(element('i'));
    if(id==='none'&&image){const img=element('img');img.alt='';img.src=image;pic.append(img);}
    b.prepend(pic);return b;
  }));
  byId('filters').replaceChildren(...Object.entries(groups).map(([id,label])=>control(label,'filter',id,true,id===category)));
  byId('slots').replaceChildren(...Object.entries(groups).slice(1).map(([id,label])=>{
    const slot=element('div','','slot'),b=control('','inspect',id,true,id===inspector);
    b.append(element('small',label),element('b',name(id)||(id==='actor'?modes.find(m=>m[0]===state.mode)[1]:id==='scene'?visibleScene:id==='voice'?state.voice.name:'导入背景音')));
    slot.append(b);return slot;
  }));
  drawCards(items);
  drawInspector();drawRoutes();
  if(owner&&key&&document.activeElement!==focus)Array.from(owner.querySelectorAll('button,input')).find(b=>b.dataset.action===key&&b.dataset.value===val&&!b.disabled)?.focus({preventScroll:true});
}
function canPreview(){
  return Boolean(state.video && (state.mode!=='none' || !['original','plate'].includes(state.scene)));
}
function drawInspector(){
  const box=byId('inspector');box.hidden=!inspector;if(!inspector)return;
  const row=element('div');row.append(element('h3',groups[inspector]));
  row.append(control('换素材','filter',inspector));
  if(inspector==='voice')row.append(...choices(state.monitor,'monitor'),control('试听音色','audition','',state.auditionOK),
    control('原声','clean','dry',state.cleanOK,!state.clean),control('轻度降噪','clean','clean',state.cleanOK,state.clean));
  if(inspector==='track'){
    row.append(control('导入背景音','wav','',state.importOK),control('播放背景','play','',state.playOK,state.playing),
      control(state.paused?'继续':'暂停','pause','',state.pauseOK),control('循环','loop','',state.loopOK,state.loop),control('移除','clear','',state.removeOK));
    const label=element('label','背景音量');const gain=element('input');gain.type='range';gain.min=0;gain.max=100;gain.value=Math.round(state.gain*100);gain.disabled=!state.gainOK;gain.dataset.action='gain';label.append(gain);row.append(label);
  }
  if(inspector==='actor'||inspector==='scene')row.append(control('打开画面预览','runtime','',canPreview()));
  box.replaceChildren(row);
}
function drawRoutes(){
  const lanes=byId('lanes');lanes.replaceChildren();
  const lane=(title,devices,action)=>{
    const el=element('div','','patch-lane'),ends=element('div','','endpoint-options');
    ends.append(...devices);el.append(element('strong',title,'source'),element('i','','wire'),ends,action);lanes.append(el);
  };
  const audio=state.audio.items.filter(i=>i.id).map(i=>{
    const selected=i.id===state.audio.selected;
    return control(i.name,'audio',selected?'':i.id,selected||state.audio.enabled,selected);
  });
  lane('声音',audio,control('允许发送语音','arm','',state.armOK,state.armed));
  const video=[['obs','OBS Virtual Camera'],['callbridge','CallBridge Camera']].map(([id,label])=>control(label,'video',state.video===id?'':id,true,state.video===id));
  lane('画面',video,control('打开画面预览','runtime','',canPreview()));
  byId('mic-tools').replaceChildren(...choices(state.mic,'mic'),control('混入环境音','micOn','',state.micOK,state.micOn));
}
document.addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b||b.disabled)return;
  if(b.id==='mix-view'||b.id==='route-view'){
    const tab=b.id==='route-view'?'route':'mix';view(tab);void request('tab',tab);return;
  }
  const {action,value=''}=b.dataset;
  if(action==='filter'){category=value;draw();return;}
  if(action==='inspect'){openInspector(value);return;}
  if(action)void request(action,value);
});
document.addEventListener('change',e=>{if(e.target.dataset.action==='gain')void request('gain',String(Number(e.target.value)/100));});
