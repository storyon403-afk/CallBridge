// 本文件的目的：把头脸、肩臂和掌指快照转换成半身角色本地动作，并在渲染帧间连续插值。
// 推理只更新目标，不能每帧重置骨架；失踪信号短暂保留后回中性，主动停止立即清空。
import {Euler,Quaternion,Vector3} from 'three';
import {Face} from 'kalidokit/dist/kalidokit.es.js';
import {bounded} from './rig.mjs';
import {RotationFilter} from './rotation-filter.mjs';
import {palmBasis} from './signals.mjs';

export const boneKey=name=>{
 const converted=name.replace('ThumbProximal','ThumbMetacarpal').replace('ThumbIntermediate','ThumbProximal');
 return converted[0].toLowerCase()+converted.slice(1);
};
// VRM0 面向 -Z、VRM1 面向 +Z：用 Y 轴半周的基变换 C Q C^-1，而非只旋转整个角色。
// 对 XYZ 等 Euler 顺序，这等价于 x/z 变号、y 不变；拇指和手臂也必须经过同一转换。
export function rotationQuaternion(rotation,version='1',scale=1){
 const flip=version==='0'?1:-1;
 const order=['XYZ','XZY','YXZ','YZX','ZXY','ZYX'].includes(rotation?.rotationOrder)?rotation.rotationOrder:'XYZ';
 return new Quaternion().setFromEuler(new Euler(bounded(rotation?.x)*scale*flip,bounded(rotation?.y)*scale,bounded(rotation?.z)*scale*flip,order));
}
// 与实际经过的秒数相关；30/60/120 Hz 都有相同收敛速度，不再依赖推理帧数。
export const follow=(dt,tau)=>1-Math.exp(-Math.max(0,dt)/tau);
const sides=['Left','Right'],fingers=['Ring','Index','Middle','Thumb','Little'];
const mouth={A:'aa',I:'ih',E:'ee',O:'oh',U:'ou'};
const neutralFace={blink:0,blinkLeft:0,blinkRight:0,aa:0,ih:0,ee:0,oh:0,ou:0};

export class AvatarMotion{
 constructor(vrm){
  this.vrm=vrm;this.version=vrm.meta?.metaVersion??'1';this.bones=new Map();this.seen=new Map();
  this.faceTarget={...neutralFace};this.lookTarget={yaw:0,pitch:0};
  const add=(name,group,tau=.065)=>{
   const node=vrm.humanoid.getNormalizedBoneNode(boneKey(name));if(!node)return;
   const rest=node.quaternion.clone();
   if(name.endsWith('UpperArm'))rest.copy(rotationQuaternion({z:name.startsWith('Left')?1.25:-1.25},this.version));
   this.bones.set(name,{node,rest,target:rest.clone(),group,tau,time:null,world:false,filter:new RotationFilter()});
  };
  add('Hips','fixed');
  for(const name of ['Spine','Chest','UpperChest'])add(name,'torso',.025);
  for(const side of sides){
   for(const bone of ['UpperArm','LowerArm'])add(side+bone,side+'Arm');
   for(const bone of ['UpperLeg','LowerLeg','Foot'])add(side+bone,'fixed');
   add(side+'Hand',side+'Hand',.05);
   for(const finger of fingers)for(const segment of ['Proximal','Intermediate','Distal'])add(side+finger+segment,side+'Hand',.045);
  }
  // 父骨先更新，颈部最后才用当前父骨世界旋转求逆；不能只减未平滑的髋部 yaw。
  add('Neck','face');
  this.hips=vrm.humanoid.getNormalizedBoneNode('hips');
  this.space=this.hips?.parent?.getWorldQuaternion(new Quaternion())??new Quaternion();
  this.chest=['UpperChest','Chest','Spine'].find(n=>this.bones.has(n));
  this.parentRotation=new Quaternion();this.localTarget=new Quaternion();
  this.restPosition=this.hips?.position.clone()??new Vector3();
  this.armBindings=new Map();this.handBindings=new Map();this.fingerBindings=new Map();
  const position=name=>this.bones.get(name)?.node.getWorldPosition(new Vector3());
  for(const side of sides){
   for(const [name,child] of [['UpperArm','LowerArm'],['LowerArm','Hand']]){
    const a=position(side+name),b=position(side+child),node=this.bones.get(side+name)?.node;
    if(a&&b&&a.distanceTo(b)>.001)this.armBindings.set(side+name,{direction:b.sub(a).normalize(),rotation:node.getWorldQuaternion(new Quaternion())});
   }
   const names=['Hand','MiddleProximal','IndexProximal','LittleProximal'].map(n=>position(side+n));
   const basis=names.every(Boolean)?palmBasis(...names):null;
   if(basis)this.handBindings.set(side,{inverse:basis.invert(),rotation:this.bones.get(side+'Hand').node.getWorldQuaternion(new Quaternion())});
   for(const finger of fingers){
    const segments=['Proximal','Intermediate','Distal'];
    for(const [i,segment] of segments.entries()){
     const key=side+finger+segment,node=this.bones.get(key)?.node,a=position(key);
     let b=i<2?position(side+finger+segments[i+1]):null;
     // VRM 不要求指尖末端骨；没有末端节点时沿最后一节静止骨段延长，不新增骨骼。
     if(!b&&a){const previous=position(side+finger+'Intermediate');if(previous)b=a.clone().add(a.clone().sub(previous));}
     if(a&&b&&a.distanceTo(b)>.0001)this.fingerBindings.set(key,{direction:b.sub(a).normalize(),rotation:node.getWorldQuaternion(new Quaternion())});
    }
   }
  }
  this.reset();
 }
 reset(){
  this.seen.clear();
  for(const b of this.bones.values()){b.target.copy(b.rest);b.node.quaternion.copy(b.rest);b.filter.reset();b.time=null;b.world=false;}
  this.hips?.position.copy(this.restPosition);
  for(const [name,value] of Object.entries(neutralFace)){this.faceTarget[name]=value;this.vrm.expressionManager?.setValue(name,value);}
  this.lookTarget={yaw:0,pitch:0};this.vrm.lookAt?.reset();
 }
 target(name,rotation,time,world=false){
  const bone=this.bones.get(name);
  // 缺失/非有限旋转不是零角度；拒绝它，允许该骨自己的有效时间正常过期。
  if(!bone||!rotation||!['x','y','z'].every(k=>Number.isFinite(rotation[k])))return;
  const q=rotationQuaternion(rotation,this.version);
  if(world)q.premultiply(this.space);
  this.targetQuaternion(name,q,time,world);
 }
 targetQuaternion(name,q,time,world=false){
  const bone=this.bones.get(name);if(!bone||bone.group==='fixed'||!q.toArray().every(Number.isFinite))return;
  const filtered=bone.group==='face'||bone.group.endsWith('Hand')?q:bone.filter.sample(q,time);
  if(!filtered)return;
  bone.target.copy(filtered);bone.world=world;bone.time=time;this.seen.set(bone.group,time);
 }
 accept(rig,time){
  const p=rig.pose,f=rig.face;
  if(p){
   // 肩线是相机空间的躯干方向，集中写入一个胸骨；不能在每节脊柱重复叠加。
   if(rig.visible?.torso!==false&&p.Spine){
    const r=p.Spine;
    if(['x','y','z'].every(k=>Number.isFinite(r[k])))this.target(this.chest,{x:0,y:bounded(r.y,-.75,.75),z:bounded(r.z,-.3,.3)},time,true);
   }
   for(const side of sides){
    if(rig.visible?.[side+'Arm']===false)continue;
    for(const name of ['UpperArm','LowerArm']){
     const key=side+name,bind=this.armBindings.get(key),direction=rig.directions?.[key];
     if(bind&&direction?.length===3&&direction.every(Number.isFinite)){
      const d=new Vector3().fromArray(direction);
      if(d.lengthSq()>.001)this.targetQuaternion(key,new Quaternion().setFromUnitVectors(bind.direction,d.normalize()).multiply(bind.rotation),time,true);
     }else this.target(key,p[key],time,name==='UpperArm');
    }
   }
   // 半身像固定髋部与双腿。即使检测到全身，也不恢复走动和足底补偿。
  }
  if(f){
   if(['x','y','z'].every(k=>Number.isFinite(f.head?.[k])))this.target('Neck',
    {x:bounded(f.head.x,-.8,.8),y:bounded(f.head.y,-1.4,1.4),z:bounded(f.head.z*.8,-.3,.3)},time,true);
   const eye=Face.stabilizeBlink({...f.eye},f.head.y,{enableWink:true,maxRot:.5});
   // 同时眨眼使用公共 blink，避免只有公共 blink 的 VRM 角色完全不眨眼。
   const left=bounded(1-eye.l,0,1),right=bounded(1-eye.r,0,1),common=Math.min(left,right);
   this.faceTarget.blink=common;this.faceTarget.blinkLeft=left-common;this.faceTarget.blinkRight=right-common;
   for(const [key,name] of Object.entries(mouth))this.faceTarget[name]=bounded(f.mouth.shape[key],0,1);
   // 新版 lookAt 使用角度（度），KalidoKit 的 pupil 由旧版按弧度使用；不能随意乘 15/25。
   if(eye.l>.5&&eye.r>.5){this.lookTarget.yaw=bounded(f.pupil.x,-1,1)*180/Math.PI;this.lookTarget.pitch=bounded(f.pupil.y,-1,1)*180/Math.PI;}
  }
  for(const [side,hand] of Object.entries(rig.hands??{})){
   const wrist=hand[side+'Wrist'],frame=rig.handFrames?.[side],bind=this.handBindings.get(side);
   if(bind&&frame?.length===4&&frame.every(Number.isFinite)){
    // 掌面朝向先消除模型静止掌面，再按实际前臂父骨转换；不再用姿态手腕 z 覆盖手部结果。
    this.targetQuaternion(side+'Hand',new Quaternion().fromArray(frame).multiply(bind.inverse).multiply(bind.rotation),time,true);
   }else this.target(side+'Hand',wrist,time);
   for(const finger of fingers)for(const segment of ['Proximal','Intermediate','Distal']){
    const key=side+finger+segment,bind=this.fingerBindings.get(key),direction=rig.fingerDirections?.[key];
    if(bind&&direction?.length===3&&direction.every(Number.isFinite)){
     const d=new Vector3().fromArray(direction);
     if(d.lengthSq()>.001)this.targetQuaternion(key,new Quaternion().setFromUnitVectors(bind.direction,d.normalize()).multiply(bind.rotation),time,true);
    }else this.target(key,hand[key],time);
   }
  }
 }
 tick(dt,time,hold=false,idle=false){
  // 短遮挡 250 ms 内不抖回 T-pose；超过期限平滑归零。停止绕过此宽限立即 reset。
  const valid=group=>this.seen.has(group)&&(hold||time-this.seen.get(group)<=250);
  for(const b of this.bones.values()){
   const fresh=b.time!==null&&(hold||time-b.time<=250);
   this.localTarget.copy(fresh?b.target:b.rest);
   if(fresh&&b.world){
    this.parentRotation.identity();b.node.parent?.getWorldQuaternion(this.parentRotation);
    this.localTarget.premultiply(this.parentRotation.invert());
   }
   const filtered=b.group!=='face'&&!b.group.endsWith('Hand');
   const angle=b.node.quaternion.angleTo(this.localTarget);
   // 已在推理端自适应滤波，渲染端只补间；限制重获目标的单帧转速（rad/s）。
   const a=Math.min(follow(dt,fresh?(filtered ? .025 : b.tau):.12),angle>1e-8?12*dt/angle:1);
   b.node.quaternion.slerp(this.localTarget,a);
  }
  this.hips?.position.copy(this.restPosition);
  // 待机只做轻微呼吸和自然眨眼，保持居中，不继续使用最后一帧张嘴或手势。
  if(idle){
   const chest=this.bones.get(this.chest);
   if(chest)chest.node.quaternion.copy(chest.rest).multiply(new Quaternion().setFromEuler(new Euler(.008*Math.sin(time/1000*1.6),0,0)));
  }
  const face=valid('face'),manager=this.vrm.expressionManager;
  for(const name of Object.keys(neutralFace)){
   const current=manager?.getValue(name)??0;
   const blink=idle&&name==='blink'?Math.max(0,1-Math.abs((time/1000%4.6)-4.3)/.12):0;
   const target=idle?blink:(face?this.faceTarget[name]:0);
   // 眼睑快速闭合以保留短眨眼，其余变化平滑跟随。
   const tau=(name.startsWith('blink')&&target>current) ? .025 : .065;
   manager?.setValue(name,current+(target-current)*follow(dt,tau));
  }
  if(this.vrm.lookAt){const look=this.vrm.lookAt,a=follow(dt,.09);look.yaw+=((face?this.lookTarget.yaw:0)-look.yaw)*a;look.pitch+=((face?this.lookTarget.pitch:0)-look.pitch)*a;}
 }
}
