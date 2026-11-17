// 帧角色仅解释有界图集与固定状态，不执行资源中的代码；跟踪复用宿主的数值快照。
const expressions=['neutral','blink','talk','smile','frown'];
const clamp=(v,a,b)=>Number.isFinite(v)?Math.max(a,Math.min(b,v)):0;
export function parseFrameAvatar(buffer){
 const bytes=new Uint8Array(buffer),view=new DataView(buffer);
 if(bytes.length<45||bytes.length>16*1024*1024||String.fromCharCode(...bytes.subarray(0,4))!=='CBFA'||view.getUint32(4,true)!==1)throw Error('帧角色格式无效');
 const length=view.getUint32(8,true),offset=12+length;
 if(length>4096||offset+33>bytes.length)throw Error('帧角色头越界');
 const meta=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes.subarray(12,offset)));
 if(Object.keys(meta).sort().join(',')!=='columns,expressions,height,rows,width,yaws'||
  ![meta.width,meta.height].every(n=>Number.isInteger(n)&&n>=5&&n<=4096)||
  meta.columns!==5||meta.rows!==5||JSON.stringify(meta.expressions)!==JSON.stringify(expressions)||
  JSON.stringify(meta.yaws)!==JSON.stringify([-.5,-.25,0,.25,.5]))throw Error('帧角色布局不受支持');
 const png=bytes.subarray(offset),p=new DataView(buffer,offset);
 if([...png.subarray(0,8)].join(',')!=='137,80,78,71,13,10,26,10'||p.getUint32(8)!==13||
  String.fromCharCode(...png.subarray(12,16))!=='IHDR'||p.getUint32(16)!==meta.width||p.getUint32(20)!==meta.height||png[24]!==8||png[25]!==6)throw Error('帧角色需要尺寸一致的 RGBA PNG');
 return {meta,png};
}
export class FrameSelector{
 constructor(){this.reset();}
 reset(){this.yaw=0;this.roll=0;this.lean=0;this.pitch=0;this.column=2;this.row=0;this.lastSeen=-Infinity;this.lastChange=-Infinity;this.lastTick=null;this.target={};this.emotion=0;this.pendingEmotion=0;this.emotionSince=0;this.emotionSamples=0;}
 accept(rig,now){
  if(rig?.framing?.person===false)return;
  const face=rig?.face;
  if(!face)return;
  if(now-this.lastSeen>700){this.emotion=0;this.pendingEmotion=0;this.emotionSamples=0;}
  const signals=rig.frameSignals;
  const mouth=Number.isFinite(signals?.open)?clamp(signals.open,0,1):Math.max(0,...Object.values(face.mouth?.shape??{}).map(v=>clamp(v,0,1)));
  const smile=clamp(signals?.smile,0,1),frown=clamp(signals?.frown,0,1);
  const emotion=smile>(this.emotion===3?.30:.50)?3:frown>(this.emotion===4?.30:.55)?4:0;
  if(emotion===this.emotion){this.pendingEmotion=emotion;this.emotionSamples=0;}
  else{
   if(emotion!==this.pendingEmotion||this.emotionSamples===0){this.pendingEmotion=emotion;this.emotionSince=now;this.emotionSamples=1;}
   else this.emotionSamples++;
   // 至少连续两次有效推理再切换；释放稍慢，避免嘴角在边界附近来回闪动。
   if(this.emotionSamples>=2&&now-this.emotionSince>=(emotion===0?120:70))this.emotion=emotion;
  }
  const eyes=face.eye;
  // 瞬时闭眼优先显示，避免被口型抢走；图集并无闭眼张嘴的组合，不声称独立混合。
  const blink=Number.isFinite(signals?.eyeLeft)&&Number.isFinite(signals?.eyeRight)?
   Math.max(signals.eyeLeft,signals.eyeRight)<.075:
   eyes&&Number.isFinite(eyes.l)&&Number.isFinite(eyes.r)&&Math.max(eyes.l,eyes.r)<.3;
  const shoulder=clamp(rig.shoulderTilt,-.4,.4);
  const lean=clamp(Math.sign(shoulder)*Math.max(0,Math.abs(shoulder)-.04)*.20,-.035,.035);
  this.target={yaw:clamp(face.head?.y,-.5,.5),roll:clamp(face.head?.z,-.22,.22),pitch:clamp(face.head?.x,-.25,.25),
   lean,row:blink?1:this.emotion|| (mouth>(this.target.row===2?.16:.24)?2:0)};
  this.lastSeen=now;
 }
 tick(now,hold=false){
  const dt=this.lastTick===null?1/60:clamp((now-this.lastTick)/1000,0,.1);this.lastTick=now;
  const idle=this.lastSeen===-Infinity||(!hold&&now-this.lastSeen>700),t=idle?{yaw:0,roll:0,pitch:0,lean:0,row:0}:this.target;
  const blend=1-Math.exp(-dt/.065);
  for(const key of ['yaw','roll','pitch','lean'])this[key]+=(t[key]-this[key])*blend;
  const candidate=Math.round((this.yaw+.5)/.25),center=-.5+this.column*.25;
  // 相邻角度多保留 0.035 rad，抑制边界附近的左右闪烁；每次只选已有姿态。
  if(candidate!==this.column&&Math.abs(this.yaw-center)>.16&&now-this.lastChange>=65){this.column=candidate;this.lastChange=now;}
  this.row=t.row??0;
  return {column:this.column,row:this.row,index:this.row*5+this.column,expression:expressions[this.row],roll:this.roll,lean:this.lean,pitch:this.pitch,idle};
 }
}
export class FrameAvatar{
 static async load(buffer){
  const {meta,png}=parseFrameAvatar(buffer),url=URL.createObjectURL(new Blob([png],{type:'image/png'}));
  try{const image=new Image();image.src=url;await image.decode();if(image.naturalWidth!==meta.width||image.naturalHeight!==meta.height)throw Error('图集解码尺寸不符');return new FrameAvatar(meta,image);}
  finally{URL.revokeObjectURL(url);}
 }
 constructor(meta,image){this.meta=meta;this.image=image;this.selector=new FrameSelector();this.canvas=document.createElement('canvas');this.state=null;}
 reset(){this.selector.reset();}
 accept(rig,now){this.selector.accept(rig,now);}
 render(width,height,now,hold=false){
  if(this.canvas.width!==width||this.canvas.height!==height){this.canvas.width=width;this.canvas.height=height;}
  const c=this.canvas.getContext('2d'),s=this.selector.tick(now,hold),m=this.meta;this.state=s;
  c.clearRect(0,0,width,height);
  const x=Math.floor(s.column*m.width/5),y=Math.floor(s.row*m.height/5),w=Math.floor((s.column+1)*m.width/5)-x,h=Math.floor((s.row+1)*m.height/5)-y;
  const size=Math.min(height*.98,width*.95);
  // 现有图集没有独立的头颈层，不能把头部角度旋转到整个人物上；身体只跟随最多约 2° 的肩斜。
  c.save();c.translate(width/2,height*1.04);c.rotate(s.lean);
  c.drawImage(this.image,x,y,w,h,-size/2,-size,size,size);c.restore();
  return this.canvas;
 }
}
