// 本文件的目的：用原生 App 截图演示收起、恢复与并排；不嵌入模拟桌面。
// 离开展示位、页面隐藏或切换语言时停止计时，不启动任何媒体服务。
window.CBExperience={mount(host,language){
 const zh=language==='zh',titles=zh?['打开面板','进入画面','收起为组件','双击恢复','并排操作']:['Open panel','Open video','Compact widgets','Restore panels','Work side by side'];
 // 页面语言同时选择整套原生截图，不能只替换动画按钮和小组件标签。
 const imagePrefix=zh?'media/ui-':'media/ui-en-';
 const shell=document.createElement('div');shell.className='experience';
 shell.innerHTML=`<div class="experience-viewport"><div class="experience-scene"><img class="experience-window experience-main" src="${imagePrefix}main.png" alt="${zh?'CallBridge 主面板':'CallBridge main panel'}"><img class="experience-window experience-video" src="${imagePrefix}video.png" alt="${zh?'画面处理':'Video effects'}"><img class="experience-window experience-text" src="${imagePrefix}text.png" alt="${zh?'文字输入':'Text input'}"><span class="experience-capsule capsule-main">${zh?'CallBridge 主面板':'CallBridge Main'}</span><span class="experience-capsule capsule-video">${zh?'画面处理':'Video effects'}</span></div></div><div class="experience-controls"><button class="experience-play" type="button"></button><div class="experience-steps" role="group" aria-label="${zh?'演示步骤':'Demo steps'}"></div><button class="experience-replay" type="button">${zh?'重播':'Replay'}</button></div>`;
 host.append(shell);const scene=shell.querySelector('.experience-scene'),play=shell.querySelector('.experience-play'),steps=shell.querySelector('.experience-steps'),viewport=shell.querySelector('.experience-viewport');
 let step=0,visible=false,timer=null,wantsPlay=!matchMedia('(prefers-reduced-motion: reduce)').matches;
 const positions=[
  {main:[280,100,1,1],video:[280,100,1,0],text:[72,100,1,0],a:[395,24,0],b:[519,24,0]},
  {main:[395,24,.16,0],video:[280,100,1,1],text:[72,100,1,0],a:[395,24,1],b:[519,24,0]},
  {main:[341,24,.16,0],video:[519,24,.16,0],text:[72,100,1,0],a:[341,24,1],b:[519,24,1]},
  {main:[72,100,1,1],video:[488,100,1,1],text:[72,100,1,0],a:[341,24,0],b:[519,24,0]},
  {main:[395,24,.16,0],video:[488,100,1,1],text:[72,100,1,1],a:[395,24,1],b:[519,24,0]}
 ];
 titles.forEach((title,index)=>{const button=document.createElement('button');button.type='button';button.title=title;button.setAttribute('aria-label',title);button.addEventListener('click',()=>{step=index;wantsPlay=false;render();sync()});steps.append(button)});
 function render(){const p=positions[step];for(const key of ['main','video','text']){const [x,y,scale,opacity]=p[key],el=scene.querySelector('.experience-'+key);el.style.transform=`translate(${x}px,${y}px) scale(${scale})`;el.style.opacity=opacity;el.setAttribute('aria-hidden',String(!opacity))}for(const [key,cls] of [['a','main'],['b','video']]){const [x,y,opacity]=p[key],el=scene.querySelector('.capsule-'+cls);el.style.transform=`translate(${x}px,${y}px)`;el.style.opacity=opacity;el.setAttribute('aria-hidden',String(!opacity))}Array.from(steps.children).forEach((b,i)=>b.setAttribute('aria-pressed',String(i===step)));scene.dataset.step=step;}
 function sync(){clearInterval(timer);timer=null;play.textContent=wantsPlay?(zh?'暂停':'Pause'):(zh?'播放':'Play');play.setAttribute('aria-label',zh?(wantsPlay?'暂停使用体验演示':'播放使用体验演示'):(wantsPlay?'Pause experience demo':'Play experience demo'));if(wantsPlay&&visible&&!document.hidden)timer=setInterval(()=>{step=(step+1)%positions.length;render()},2600)}
 play.addEventListener('click',()=>{wantsPlay=!wantsPlay;sync()});shell.querySelector('.experience-replay').addEventListener('click',()=>{step=0;wantsPlay=true;render();sync()});
 const resize=new ResizeObserver(()=>{const width=viewport.clientWidth;scene.style.transform=`scale(${width/960})`;viewport.style.height=width*500/960+'px'});resize.observe(viewport);
 const observer=new IntersectionObserver(entries=>{visible=entries[0].isIntersecting;sync()},{threshold:.15});observer.observe(shell);document.addEventListener('visibilitychange',sync);
 render();sync();return()=>{clearInterval(timer);observer.disconnect();resize.disconnect();document.removeEventListener('visibilitychange',sync)};
}};
