// 本文件的目的：同步展示素材、说明与语言；视频均由用户主动播放，不采集音视频。
(()=>{
 const $=id=>document.getElementById(id),items=window.CALLBRIDGE_SHOWCASE;
 let active=0,language='en',disposeExperience=null;
 try{language=localStorage.getItem('callbridge-site-language')==='zh'?'zh':'en';}catch{}
 const text=value=>value[language]??value.zh;
 const label=(zh,en)=>language==='zh'?zh:en;
 function video(src,poster,muted=false){const v=document.createElement('video');v.src=src;if(poster)v.poster=poster;v.controls=true;v.playsInline=true;v.preload='none';v.muted=muted;return v;}
 function frame(caption,source,poster,kind){const figure=document.createElement('figure');figure.className='media-frame '+kind;const title=document.createElement('figcaption');title.textContent=caption;const v=video(source,poster,kind==='workflow');v.setAttribute('aria-label',caption);figure.append(title,v);return figure;}
 // 展示卡片只保留名称与能力短语，不添加无实际操作的按钮。
 function featureOverview(item,panel){
  const overview=document.createElement('div');overview.className='feature-overview';
  const heading=document.createElement('h3');heading.textContent=text(item.heading);overview.append(heading);
  const grid=document.createElement('div');grid.className='feature-grid';
  item.cards.forEach(card=>{const article=document.createElement('article');article.className='feature-card';const title=document.createElement('h4');title.textContent=text(card.title);const body=document.createElement('p');body.textContent=text(card.body);article.append(title,body);grid.append(article);});
  overview.append(grid);panel.append(overview);
 }
 function render(){
  disposeExperience?.();disposeExperience=null;
  const tabs=$('tabs'),panel=$('media-panel');panel.querySelectorAll('video').forEach(v=>{v.pause();v.removeAttribute('src');v.load();});panel.replaceChildren();tabs.replaceChildren();
  items.forEach((item,i)=>{const b=document.createElement('button');b.type='button';b.id='tab-'+item.id;b.setAttribute('role','tab');b.setAttribute('aria-selected',String(i===active));b.setAttribute('aria-controls','media-panel');b.tabIndex=i===active?0:-1;b.textContent=text(item.title);b.addEventListener('click',()=>{active=i;render();$('tab-'+item.id).focus({preventScroll:true});});tabs.append(b);});
  const item=items[active];panel.setAttribute('aria-labelledby','tab-'+item.id);panel.dataset.item=item.id;$('counter').textContent=String(active+1).padStart(2,'0')+' / '+String(items.length).padStart(2,'0');$('showcase-caption').textContent=item.description?text(item.description):'';$('showcase-caption').hidden=!item.description;
  if(item.description)panel.setAttribute('aria-describedby','showcase-caption');else panel.removeAttribute('aria-describedby');
  panel.classList.toggle('feature-panel',item.type==='features');
  if(item.type==='studio'){disposeExperience=window.CBStudio.mount(panel,language);}
  else if(item.type==='features'){featureOverview(item,panel);}
  else if(item.type==='recordings'){const wrap=document.createElement('div'),choice=document.createElement('div'),body=document.createElement('div');wrap.className='recordings';choice.className='recording-choice';choice.setAttribute('role','group');choice.setAttribute('aria-label',label('选择微信实录','Choose a WeChat recording'));function show(index){body.querySelectorAll('video').forEach(v=>v.pause());body.replaceChildren();const row=item.items[index];body.className='paired-media';const arrow=document.createElement('span');arrow.className='arrow';arrow.textContent='→';body.append(frame(label('操作流程','Workflow'),row.operation,row.operationPoster,'workflow'),arrow,frame(label('微信端效果 · 播放声音','WeChat result · play with sound'),row.result,row.poster,'result'));Array.from(choice.children).forEach((b,i)=>b.setAttribute('aria-pressed',String(i===index)));}item.items.forEach((row,i)=>{const b=document.createElement('button');b.textContent=text(row.title);b.onclick=()=>show(i);choice.append(b);});wrap.append(choice,body);panel.append(wrap);show(0);}
  else if(item.type==='experience'){disposeExperience=window.CBExperience.mount(panel,language);}
  else if(item.type==='pair'&&item.operation&&item.result){const pair=document.createElement('div');pair.className='paired-media';const arrow=document.createElement('span');arrow.className='arrow';arrow.textContent='→';arrow.setAttribute('aria-hidden','true');pair.append(frame(label('操作流程','Workflow'),item.operation,item.operationPoster,'workflow'),arrow,frame(label('微信端效果','WeChat result'),item.result,item.poster,'result'));panel.append(pair);}
  else if(item.src){const figure=document.createElement('figure');figure.className='single-media';let media;if(item.type==='image'){media=document.createElement('img');media.src=item.src;media.alt=text(item.title);}else{media=video(item.src,item.poster);media.setAttribute('aria-label',text(item.title));}figure.append(media);panel.append(figure);}
  else{const holder=document.createElement('div');holder.className='placeholder';const mark=document.createElement('span');mark.className='placeholder-mark';mark.textContent='+';mark.setAttribute('aria-hidden','true');const caption=document.createElement('span');caption.className='placeholder-label';caption.textContent=label('待添加','Coming soon');holder.append(mark,caption);panel.append(holder);}
 }
 function translate(){document.documentElement.lang=language==='zh'?'zh-CN':'en';document.querySelectorAll('[data-zh][data-en]').forEach(el=>el.textContent=el.dataset[language]);$('language').textContent=label('EN','中文');$('language').setAttribute('aria-label',label('Switch to English','切换到中文'));render();}
 $('language').addEventListener('click',()=>{language=language==='zh'?'en':'zh';try{localStorage.setItem('callbridge-site-language',language);}catch{}translate();});
 $('tabs').addEventListener('keydown',e=>{let next=active;if(e.key==='ArrowRight')next=(active+1)%items.length;else if(e.key==='ArrowLeft')next=(active+items.length-1)%items.length;else if(e.key==='Home')next=0;else if(e.key==='End')next=items.length-1;else return;e.preventDefault();active=next;render();$('tab-'+items[active].id).focus({preventScroll:true});});
 document.addEventListener('visibilitychange',()=>{if(document.hidden)$('media-panel').querySelectorAll('video').forEach(v=>v.pause());});
 translate();
})();
