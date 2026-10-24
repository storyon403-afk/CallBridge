// 本文件的目的：独立选择人物与背景，准备静音视频或无模型的分层动画。
// 两个槽分别单选，拒绝尚未实现的真人替换；媒体只来自固定本机路径，不接触音频管线。
export function composition(value={}) {
 const person=value.person??'avatar',background=value.background??'original';
 if(!['none','avatar'].includes(person)||!['original','plate','sample','parallax','custom'].includes(background))throw Error('画面组合不支持');
 return Object.freeze({person,background});
}
export function drawParallax(ctx,w,h,now,head=0) {
 // 同一场景分远山、窗框、近景三层，位移不同产生 2.5D 视差；不是场景重建或自由视点。
 const drift=Math.max(-1,Math.min(1,Number.isFinite(head)?head:0)),t=now/1000;
 const sky=ctx.createLinearGradient(0,0,0,h);sky.addColorStop(0,'#203c58');sky.addColorStop(.7,'#b2d1cc');sky.addColorStop(1,'#f4dab4');ctx.fillStyle=sky;ctx.fillRect(0,0,w,h);
 ctx.fillStyle='#f5dbaf';ctx.beginPath();ctx.arc(w*.72-drift*8,h*.23,h*.08,0,Math.PI*2);ctx.fill();
 for(let layer=0;layer<3;layer++){
  ctx.fillStyle=['#718f96','#4e767e','#305c64'][layer];ctx.beginPath();ctx.moveTo(0,h);
  for(let x=-20;x<=w+20;x+=10)ctx.lineTo(x,h*(.59+layer*.1)+Math.sin((x+drift*(10+layer*12))/w*8+layer)*h*.055);
  ctx.lineTo(w,h);ctx.closePath();ctx.fill();
 }
 ctx.fillStyle='#e3d9c6';const shift=drift*24;ctx.fillRect(w*.12+shift,0,w*.025,h);ctx.fillRect(w*.87+shift,0,w*.025,h);ctx.fillRect(0,h*.16,w,h*.018);
 ctx.fillStyle='#c6b697';ctx.fillRect(0,h*.83,w,h*.17);ctx.fillStyle='#88745b';ctx.fillRect(0,h*.83,w,h*.018);
 ctx.save();ctx.translate(w*.14+drift*38,h*.85);ctx.fillStyle='#c3a17d';ctx.fillRect(-w*.025,-h*.07,w*.07,h*.07);
 for(let i=0;i<7;i++){ctx.save();ctx.rotate((i-3)*.22+Math.sin(t*.6+i)*.02);ctx.fillStyle=i%2?'#467363':'#365c50';ctx.beginPath();ctx.ellipse(0,-h*.13,h*.018,h*.09,0,0,Math.PI*2);ctx.fill();ctx.restore();}ctx.restore();
}
export class BackgroundSource {
 constructor(mode){this.mode=mode;this.ready=!['sample','custom'].includes(mode);this.video=null;this.error='';}
 async prepare(){
  if(this.ready)return;
  const v=document.createElement('video');this.video=v;v.muted=true;v.defaultMuted=true;v.volume=0;v.loop=true;v.playsInline=true;v.preload='auto';
  v.src=this.mode==='sample'?'backgrounds/aurora.mp4':'background/custom';
  try {
   await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>done(Error('背景素材读取超时')),12000);
    const done=error=>{clearTimeout(timer);v.onloadeddata=null;v.onerror=null;error?reject(error):resolve();};
    v.onloadeddata=()=>done();v.onerror=()=>done(Error('背景素材不可用，请重新导入 MP4 / MOV / WebM'));v.load();
   });
   if(!Number.isFinite(v.duration)||v.duration<=0||v.duration>120||v.videoWidth<1||v.videoHeight<1||v.videoWidth>1920||v.videoHeight>1080)throw Error('背景素材限制为 1080p、120 秒以内');
   this.ready=true;
  }catch(error){this.error=error.message;v.pause();v.removeAttribute('src');v.load();throw error;}
 }
 async play(){if(this.video&&this.ready){this.video.muted=true;this.video.volume=0;await this.video.play();}}
 pause(){this.video?.pause();}
 draw(ctx,w,h,now,head){
  if(this.mode==='parallax'){drawParallax(ctx,w,h,now,head);return;}
  const v=this.video;if(!this.ready||!v||v.readyState<2)return;
  const scale=Math.max(w/v.videoWidth,h/v.videoHeight),dw=v.videoWidth*scale,dh=v.videoHeight*scale;
  ctx.drawImage(v,(w-dw)/2,(h-dh)/2,dw,dh);
 }
}
