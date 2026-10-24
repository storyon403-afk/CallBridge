// 本文件的目的：独立合成人物与背景；保留现场时用确认空背景补掉真人，只换背景时提取真人前景。
// 图像只保存在固定数量的内存画布；相机帧与同一次推理的遮罩一起发布，绝不读取更新的视频帧来套旧遮罩。
import {extendBackground} from './live-background.mjs';
export class BackgroundCapture {
 constructor(){this.reset();}
 reset(){this.state='empty';this.started=0;this.clearSince=null;this.frames=0;this.last=null;}
 begin(now){this.reset();this.state='countdown';this.started=now;}
 observe(now,occupied){
  if(this.state!=='countdown')return false;
  if(now-this.started>15000){this.state='timeout';return false;}
  if(!Number.isFinite(now)||now<this.started||(this.last!==null&&now<=this.last))return false;
  if(this.last!==null&&now-this.last>500){this.clearSince=null;this.frames=0;}
  this.last=now;
  if(occupied){this.clearSince=null;this.frames=0;return false;}
  this.clearSince??=now;this.frames++;
  // 五秒离场时间后，还要连续至少一秒/五次检测无人；检测不等于保证，之后仍需本人确认缩略图。
  if(now-this.started>=5000&&now-this.clearSince>=1000&&this.frames>=5){this.state='review';return true;}
  return false;
 }
 confirm(){if(this.state!=='review')return false;this.state='ready';return true;}
}

// 分割返回的是人物 alpha。低阈值把不确定边缘也移除；小尺寸膨胀给头发/手指留边。
// 这里只生成遮罩，不将相机颜色当透明度，也不靠模型漏检宣称“绝对无人”。
export function removalMask(rgba,width,height,radius=3){
 if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>320||height>240||rgba.length!==width*height*4)throw Error('遮罩尺寸无效');
 if(!Number.isInteger(radius)||radius<0||radius>8)throw Error('遮罩边界无效');
 const count=width*height,raw=new Uint8Array(count),horizontal=new Uint8Array(count),out=new Uint8ClampedArray(count*4);
 let occupied=0;
 for(let i=0;i<count;i++){raw[i]=rgba[i*4+3]>12?1:0;occupied+=raw[i];}
 for(let y=0;y<height;y++)for(let x=0;x<width;x++){
  for(let dx=Math.max(0,x-radius);dx<=Math.min(width-1,x+radius);dx++)if(raw[y*width+dx]){horizontal[y*width+x]=1;break;}
 }
 for(let y=0;y<height;y++)for(let x=0;x<width;x++){
  for(let dy=Math.max(0,y-radius);dy<=Math.min(height-1,y+radius);dy++)if(horizontal[dy*width+x]){out[(y*width+x)*4+3]=255;break;}
 }
 return {pixels:out,fraction:occupied/count};
}
const canvas=()=>document.createElement('canvas');
const size=(c,w,h)=>{if(c.width!==w||c.height!==h){c.width=w;c.height=h;}};
const copy=(to,from,w=from.width,h=from.height)=>{size(to,w,h);const c=to.getContext('2d');c.clearRect(0,0,w,h);c.drawImage(from,0,0,w,h);};
// 和动作驱动保持同一自拍方向；输入、遮罩、背景三者先在原始坐标处理，最终统一镜像。
function cover(ctx,source,w,h){
 const sw=source.videoWidth||source.width,sh=source.videoHeight||source.height;
 const scale=Math.max(w/sw,h/sh),dw=sw*scale,dh=sh*scale;
 ctx.save();ctx.translate(w,0);ctx.scale(-1,1);ctx.drawImage(source,(w-dw)/2,(h-dh)/2,dw,dh);ctx.restore();
}
export class ReplacementCompositor {
 constructor(output,candidate,{realtime=false}={}){
  this.output=output;this.candidate=candidate;this.capture=new BackgroundCapture();
  this.plate=canvas();this.live=canvas();this.mask=canvas();this.probe=canvas();this.at=-Infinity;
  this.raw=canvas();this.foreground=canvas();this.foregroundValid=false;
  this.realtime=realtime;this.extended=canvas();this.smallFrame=canvas();this.smallMask=canvas();this.publishedAt=-Infinity;
  this.reason='请先采集空背景';this.hasPlate=false;this.fraction=0;this.liveValid=false;
 }
 reset(){
  this.capture.reset();this.hasPlate=false;this.liveValid=false;this.foregroundValid=false;this.at=-Infinity;this.reason='请先采集空背景';this.fraction=0;
  // 重设尺寸清空像素和旧背景；停止/切源后不能继续显示上一会话的私人场景。
  this.publishedAt=-Infinity;
  for(const c of [this.plate,this.live,this.mask,this.probe,this.candidate,this.raw,this.foreground,this.extended,this.smallFrame,this.smallMask]){c.width=1;c.height=1;}
 }
 begin(now){this.reset();this.capture.begin(now);this.reason='请离开画面，保持摄像头不动';}
 confirm(){
  if(!this.capture.confirm())return false;
  copy(this.plate,this.candidate);this.candidate.width=1;this.candidate.height=1;
  this.hasPlate=true;this.reason='空背景已确认，等待人物入画';return true;
 }
 accept(frame,segmentation,landmarks,now,capturedAt=now){
  const w=frame.width,h=frame.height;
  if(!(w>0&&h>0&&w<=640&&h<=480))throw Error('合成帧尺寸无效');
  const face=landmarks.faceLandmarks??[],pose=landmarks.poseLandmarks??[];
  const occupied=face.length>0||(landmarks.leftHandLandmarks?.length??0)>0||(landmarks.rightHandLandmarks?.length??0)>0||pose.some(p=>p.visibility>.2);
  this.liveValid=false;this.at=capturedAt;
  copy(this.raw,frame);this.foregroundValid=false;
  let mask=null;
  if(segmentation){
   const mw=Math.max(1,Math.round(w/2)),mh=Math.max(1,Math.round(h/2));size(this.probe,mw,mh);
   const p=this.probe.getContext('2d',{willReadFrequently:true});p.clearRect(0,0,mw,mh);p.drawImage(segmentation,0,0,mw,mh);
   mask=removalMask(p.getImageData(0,0,mw,mh).data,mw,mh);this.fraction=mask.fraction;
   size(this.mask,mw,mh);this.mask.getContext('2d').putImageData(new ImageData(mask.pixels,mw,mh),0,0);
  }else this.fraction=0;
  // 保留真人时用同帧原始 alpha 提取前景；不能拿移除人物用的膨胀遮罩把旧背景带回来。
  if(segmentation&&mask.fraction>=.005&&mask.fraction<=.95){
   copy(this.foreground,frame);const f=this.foreground.getContext('2d');f.globalCompositeOperation='destination-in';
   f.drawImage(segmentation,0,0,w,h);f.globalCompositeOperation='source-over';this.foregroundValid=true;
  }
  if(this.capture.observe(now,occupied||(mask?.fraction??0)>.001||now-capturedAt>250||now<capturedAt))copy(this.candidate,frame);
  if(this.realtime){this.acceptRealtime(frame,mask,face,pose,landmarks,now,capturedAt);return;}
  if(!this.hasPlate)return;
  if(this.plate.width!==w||this.plate.height!==h){this.reset();this.reason='相机尺寸变化，请重新采集空背景';return;}
  // 没有可靠人像、遮罩缺失/全空/全满时只用确认过的背景。不会把全透明遮罩解释成可以放行真人。
  const finite=p=>p&&Number.isFinite(p.x)&&Number.isFinite(p.y)&&Number.isFinite(p.z);
  const shoulders=[11,12].every(i=>finite(pose[i])&&pose[i].visibility>=.6);
  if(!mask||mask.fraction<.005||mask.fraction>.95||!shoulders||face.length<468||!face.every(finite)){this.reason='当前分割不可靠，使用已确认背景';return;}
  // 关键点包围区域加保守边界，覆盖分割可能遗漏的脸/肩/手；代价是附近动态背景也会冻结。
  const pts=[...face,...pose.filter(p=>p.visibility>=.6),...(landmarks.leftHandLandmarks??[]),...(landmarks.rightHandLandmarks??[])].filter(p=>Number.isFinite(p.x)&&Number.isFinite(p.y));
  const xs=pts.map(p=>p.x),ys=pts.map(p=>p.y),mc=this.mask.getContext('2d');
  const x=Math.max(0,Math.min(...xs)-.04),y=Math.max(0,Math.min(...ys)-.04);
  const right=Math.min(1,Math.max(...xs)+.04),bottom=Math.min(1,Math.max(...ys)+.04);
  mc.fillStyle='#000';mc.fillRect(x*this.mask.width,y*this.mask.height,(right-x)*this.mask.width,(bottom-y)*this.mask.height);
  copy(this.live,frame);const ctx=this.live.getContext('2d');ctx.globalCompositeOperation='destination-out';
  // 遮罩是硬移除；缩放插值只发生在已膨胀的外围，不把真人边缘混入最终画面。
  ctx.imageSmoothingEnabled=false;ctx.drawImage(this.mask,0,0,w,h);ctx.globalCompositeOperation='source-over';
  this.liveValid=true;this.reason='人物替换中';
 }
 acceptRealtime(frame,mask,face,pose,landmarks,now,capturedAt){
  // 不要求脸和肩膀同时完整：背景分割可在侧脸/短暂丢点时继续工作。
  // 全空/全满或异常延迟不能当作“无人”；保守停用现场层，避免把真人原帧放行。
  if(!mask||mask.fraction<.005||mask.fraction>.95||!Number.isFinite(now)||!Number.isFinite(capturedAt)||now<capturedAt||now-capturedAt>1000){this.reason='等待可靠人物分割';return;}
  const mc=this.mask.getContext('2d');mc.fillStyle='#000';
  // 分别包住脸和手，防止分割漏掉边缘；不再用全身的大矩形冻结两侧环境。
  for(const points of [face,landmarks.leftHandLandmarks??[],landmarks.rightHandLandmarks??[]]){
   const valid=points.filter(p=>Number.isFinite(p.x)&&Number.isFinite(p.y));if(valid.length<3)continue;
   const xs=valid.map(p=>p.x),ys=valid.map(p=>p.y),x=Math.max(0,Math.min(...xs)-.025),y=Math.max(0,Math.min(...ys)-.025);
   mc.fillRect(x*this.mask.width,y*this.mask.height,(Math.min(1,Math.max(...xs)+.025)-x)*this.mask.width,(Math.min(1,Math.max(...ys)+.025)-y)*this.mask.height);
  }
  const w=frame.width,h=frame.height,scale=Math.min(1,80/w,60/h),sw=Math.max(1,Math.round(w*scale)),sh=Math.max(1,Math.round(h*scale));
  copy(this.smallFrame,frame,sw,sh);copy(this.smallMask,this.mask,sw,sh);
  const pixels=extendBackground(this.smallFrame.getContext('2d',{willReadFrequently:true}).getImageData(0,0,sw,sh).data,this.smallMask.getContext('2d',{willReadFrequently:true}).getImageData(0,0,sw,sh).data,sw,sh);
  if(!pixels){this.reason='没有可靠背景区域';return;}
  size(this.extended,sw,sh);this.extended.getContext('2d').putImageData(new ImageData(pixels,sw,sh),0,0);
  copy(this.live,frame);const ctx=this.live.getContext('2d');ctx.globalCompositeOperation='destination-out';ctx.imageSmoothingEnabled=false;ctx.drawImage(this.mask,0,0,w,h);ctx.globalCompositeOperation='source-over';
  // 同帧图像与遮罩完成后才发布。区分采集时间与发布时间，避免模型耗时令结果刚到就被清空。
  this.publishedAt=now;this.liveValid=true;this.reason='实时背景与虚拟人物合成中';
 }
 draw(avatar,now,{person='avatar',background='original',source=null,head=0}={}){
  const ctx=this.output.getContext('2d'),w=this.output.width,h=this.output.height;
  const fresh=now>=this.at&&now-this.at<=250;
  ctx.globalCompositeOperation='source-over';ctx.fillStyle='#dce6e0';ctx.fillRect(0,0,w,h);
  if(background==='original'&&person==='none'){
   if(fresh)cover(ctx,this.raw,w,h);
  }else if(background==='original'&&this.realtime){
   if(this.realtimeFresh(now)){cover(ctx,this.extended,w,h);cover(ctx,this.live,w,h);}
  }else if((background==='original'||background==='plate')&&this.hasPlate){
   cover(ctx,this.plate,w,h);
   if(background==='original'&&this.liveValid&&fresh)cover(ctx,this.live,w,h);
  }else if(!['original','plate'].includes(background))source?.draw(ctx,w,h,now,head);
  if(person==='avatar')ctx.drawImage(avatar,0,0,w,h);
  else if(background!=='original'&&fresh&&this.foregroundValid)cover(ctx,this.foreground,w,h);
 }
 // 用户明确保留真人和现场时直接画视频帧，不等待分割；不缓存额外原始帧。
 // 调用者确认会话有效、视频已就绪且帧未过期；停止后 draw() 会清空最终画面。
 drawOriginal(frame){cover(this.output.getContext('2d'),frame,this.output.width,this.output.height);}
 realtimeFresh(now){return this.liveValid&&now>=this.publishedAt&&now-this.publishedAt<=250&&now>=this.at&&now-this.at<=1000;}
 state(now){
  if(this.realtime)return {phase:'realtime',backgroundReady:this.realtimeFresh(now),live:this.realtimeFresh(now),maskFraction:this.fraction,message:this.realtimeFresh(now)?this.reason:'等待可靠人物分割'};
  if(this.capture.state==='countdown'&&now-this.capture.started>15000)this.capture.state='timeout';
  return {phase:this.capture.state,backgroundReady:this.hasPlate,live:this.hasPlate&&this.liveValid&&now>=this.at&&now-this.at<=250,maskFraction:this.fraction,
  message:this.capture.state==='countdown'?(now-this.capture.started<5000?`请离开画面 · ${Math.ceil((5000-(now-this.capture.started))/1000)} 秒`:'请保持离场 · 等待连续无人检测'):
   this.capture.state==='review'?'请检查缩略图，确认其中没有人物':this.capture.state==='timeout'?'未能确认空场景，请离开画面后重试':
   this.hasPlate&&now-this.at>250?'跟踪等待中，使用已确认背景':this.reason};}
}
