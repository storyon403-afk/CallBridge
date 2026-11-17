// 帧角色使用嘴角曲率而非音素权重识别表情；在眼轴/下巴构成的局部坐标中消除歪头影响。
const clamp=(n,a=0,b=1)=>Math.max(a,Math.min(b,n));
const sub=(a,b)=>a.map((v,i)=>v-b[i]);
const dot=(a,b)=>a.reduce((n,v,i)=>n+v*b[i],0);
const length=a=>Math.hypot(...a);
export function frameFaceSignals(face,width,height){
 const ids=[33,263,152,61,291,13,14];
 if(!face||!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0||
  !ids.every(i=>face[i]&&['x','y','z'].every(k=>Number.isFinite(face[i][k]))&&face[i].x>=.015&&face[i].x<=.985&&face[i].y>=.015&&face[i].y<=.985))return null;
 const p=i=>[face[i].x*width,face[i].y*height,face[i].z*width];
 const left=p(33),right=p(263),axis=sub(right,left),span=length(axis);
 if(span<8)return null;
 const x=axis.map(v=>v/span),center=left.map((v,i)=>(v+right[i])/2),chin=sub(p(152),center);
 const down=chin.map((v,i)=>v-x[i]*dot(chin,x)),downLength=length(down);
 if(downLength<span*.3)return null;
 const y=down.map(v=>v/downLength),vertical=i=>dot(sub(p(i),center),y)/span;
 const opening=Math.max(0,vertical(14)-vertical(13));
 const middle=(vertical(13)+vertical(14))/2;
 // 张嘴也会使唇中心下移，先扣除这一部分，避免把正常说话识别成笑容。
 const lift=middle-(vertical(61)+vertical(291))/2-opening*.28;
 const mouthWidth=length(sub(p(291),p(61)))/span;
 const wide=clamp((mouthWidth-.40)/.18);
 const smile=clamp((lift-.008)/.035)*(.65+.35*wide);
 const frown=opening<.12?clamp((-lift-.012)/.04):0;
 // 直接读眼睑间隙，避免上游归一化把微笑时的眯眼压成“完全闭眼”，抢走笑容帧。
 const eye=(a,b,top,bottom)=>{
  if(![a,b,top,bottom].every(i=>face[i]&&['x','y','z'].every(k=>Number.isFinite(face[i][k]))))return null;
  const w=length(sub(p(b),p(a)));return w>span*.08?length(sub(p(bottom),p(top)))/w:null;
 };
 return {smile,frown,open:clamp((opening-.015)/.24),cornerLift:lift,mouthWidth,eyeLeft:eye(33,133,159,145),eyeRight:eye(362,263,386,374)};
}
export function frameShoulderTilt(pose,width,height){
 if(!pose||!Number.isFinite(width)||!Number.isFinite(height)||width<=0||height<=0)return null;
 let a=pose[11],b=pose[12];
 if(![a,b].every(p=>p&&p.visibility>=.6&&Number.isFinite(p.x)&&Number.isFinite(p.y)&&p.x>=.015&&p.x<=.985&&p.y>=.015&&p.y<=.985))return null;
 if(a.x>b.x)[a,b]=[b,a];
 const dx=(b.x-a.x)*width,dy=(b.y-a.y)*height;
 if(dx<width*.08)return null;
 // 肩轴是图像中的实际水平线，不能把 VRM 的绝对 Spine Euler 角当成倾斜。
 return Math.atan2(dy,dx);
}
