// 本文件的目的：把相机关键点变成口型、手掌方向和入画状态；不持有相机图像。
// 图像 x/z 按宽度、y 按高度还原比例，避免宽屏输入把嘴与手掌压扁。
import {Vector3,Matrix4,Quaternion} from 'three';
const clamp=(v,lo=0,hi=1)=>Math.min(hi,Math.max(lo,v));
const inside=p=>p&&Number.isFinite(p.x)&&Number.isFinite(p.y)&&p.x>=.015&&p.x<=.985&&p.y>=.015&&p.y<=.985;
export const cameraPoint=(p,width,height)=>new Vector3(-p.x*width,-p.y*height,-p.z*width);
export function mouthShape(points,width,height){
 const distance=(a,b)=>cameraPoint(points[a],width,height).distanceTo(cameraPoint(points[b],width,height));
 const span=distance(33,263);
 if(span<1)return {A:0,I:0,E:0,O:0,U:0};
 const gap=distance(13,14)/span,widthRatio=distance(61,291)/span;
 const open=clamp((gap-.015)/.24),round=clamp((.52-widthRatio)/.18),wide=clamp((widthRatio-.52)/.18);
 // 原通用公式的 E 依赖一个最高仅为 .1 的 U，却从 .2 开始激活，导致 E 永远为零。
 // 直接按开合、圆唇、横向拉伸分配五种形态；不是从无声视频识别真实音素。
 const shape={A:open*(1-.85*round)*(1-.65*wide),
  I:open*wide*(1-open),E:open*wide*(.35+.65*open),
  O:open*round,U:round*(1-open)*Math.max(.25,open)};
 const total=Math.max(1,Object.values(shape).reduce((a,b)=>a+b,0));
 for(const key of Object.keys(shape))shape[key]/=total;
 return shape;
}
// X 沿腕到中指根，Y 在掌面内指向食指侧；Z 是正交法向。
// 此坐标架随后与角色自己的静止掌面比较，不假定 VRM 手掌朝向或只允许小角度转腕。
export function palmBasis(wrist,middle,index,little){
 const x=middle.clone().sub(wrist),y=index.clone().sub(little);
 if(x.lengthSq()<1e-10||y.lengthSq()<1e-10)return null;
 x.normalize();y.addScaledVector(x,-y.dot(x));
 if(y.lengthSq()<1e-10)return null;
 y.normalize();const z=new Vector3().crossVectors(x,y).normalize();
 return new Quaternion().setFromRotationMatrix(new Matrix4().makeBasis(x,y,z));
}
export function handBasis(points,width,height){
 if(!points||![0,5,9,17].every(i=>inside(points[i])))return null;
 const p=i=>cameraPoint(points[i],width,height);
 return palmBasis(p(0),p(9),p(5),p(17));
}
export function framing(face,pose,visible,hands){
 const hasFace=!!face&&[1,33,263,13,14].every(i=>inside(face[i]));
 const faceComplete=hasFace&&[10,152,234,454].every(i=>inside(face[i]));
 const shoulders=visible?.torso===true;
 const elbows=!!pose&&[13,14].every(i=>inside(pose[i])&&pose[i].visibility>=.6);
 return {person:hasFace||shoulders,face:hasFace,faceComplete,shoulders,
  upperComplete:faceComplete&&shoulders&&elbows,
  fullComplete:faceComplete&&elbows&&!!visible?.hips&&!!visible?.LeftArm&&!!visible?.RightArm&&!!visible?.LeftLeg&&!!visible?.RightLeg,
  hands:Object.keys(hands).length};
}
export class Presence{
 constructor(){this.reset();}
 reset(){this.lastSeen=null;this.frame=null;}
 update(frame,time){this.frame=frame;if(frame?.person)this.lastSeen=time;}
 state(time,hold=false){
  const idle=this.lastSeen===null||(!hold&&time-this.lastSeen>700);
  return {idle,framing:idle?null:this.frame};
 }
}
