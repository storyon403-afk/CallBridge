// 本文件的目的：切换展示素材与语言；视频均由用户主动播放，不采集音视频，也不添加说明段落。
(()=>{
 const $=id=>document.getElementById(id),items=window.CALLBRIDGE_SHOWCASE;
 let active=0,language='zh',disposeExperience=null;
 try{language=localStorage.getItem('callbridge-site-language')==='en'?'en':'zh';}catch{}
 const text=value=>value[language]??value.zh;
 const label=(zh,en)=>language==='zh'?zh:en;
 function video(src,poster,muted=false){const v=document.createElement('video');v.src=src;if(poster)v.poster=poster;v.controls=true;v.playsInline=true;v.preload='none';v.muted=muted;return v;}
 function frame(caption,source,poster,kind){const figure=document.createElement('figure');figure.className='media-frame '+kind;const title=document.createElement('figcaption');title.textContent=caption;const v=video(source,poster,kind==='workflow');v.setAttribute('aria-label',caption);figure.append(title,v);return figure;}
 function render(){
  disposeExperience?.();disposeExperience=null;
  const tabs=$('tabs'),panel=$('media-panel');panel.querySelectorAll('video').forEach(v=>{v.pause();v.removeAttribute('src');v.load();});panel.replaceChildren();tabs.replaceChildren();
  items.forEach((item,i)=>{const b=document.createElement('button');b.type='button';b.id='tab-'+item.id;b.setAttribute('role','tab');b.setAttribute('aria-selected',String(i===active));b.setAttribute('aria-controls','media-panel');b.tabIndex=i===active?0:-1;b.textContent=text(item.title);b.addEventListener('click',()=>{active=i;render();$('tab-'+item.id).focus({preventScroll:true});});tabs.append(b);});
  const item=items[active];panel.setAttribute('aria-labelledby','tab-'+item.id);panel.dataset.item=item.id;$('counter').textContent=String(active+1).padStart(2,'0')+' / '+String(items.length).padStart(2,'0');
  if(item.type==='experience'){disposeExperience=window.CBExperience.mount(panel,language);}
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
