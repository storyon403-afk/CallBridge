// 本文件的目的：验证迁移前会出错的坐标/父子旋转、时间平滑和丢点；无需采集设备。
import test from 'node:test';
import assert from 'node:assert/strict';
import {Object3D,Quaternion,Vector3,Euler} from 'three';
import {AvatarMotion,rotationQuaternion,boneKey} from '../src/motion.mjs';
function avatar(version='1'){
 const nodes=new Map(),values=new Map();
 for(const name of ['Hips','Spine','Chest','UpperChest','Neck',...['Left','Right'].flatMap(s=>['UpperArm','LowerArm','Hand','UpperLeg','LowerLeg','Foot',...['Ring','Index','Middle','Thumb','Little'].flatMap(f=>['Proximal','Intermediate','Distal'].map(g=>f+g))].map(n=>s+n))])nodes.set(boneKey(name),new Object3D());
 nodes.get('hips').position.y=1;
 const attach=(parent,child)=>nodes.get(parent).add(nodes.get(child));
 for(const [p,c] of [['hips','spine'],['spine','chest'],['chest','upperChest'],['upperChest','neck']])attach(p,c);
 for(const s of ['left','right']){
  attach('upperChest',s+'UpperArm');attach(s+'UpperArm',s+'LowerArm');attach(s+'LowerArm',s+'Hand');
  attach('hips',s+'UpperLeg');attach(s+'UpperLeg',s+'LowerLeg');attach(s+'LowerLeg',s+'Foot');
  nodes.get(s+'UpperLeg').position.x=s==='left'?.1:-.1;
  nodes.get(s+'LowerLeg').position.y=-.45;nodes.get(s+'Foot').position.y=-.45;
 }
 return {nodes,meta:{metaVersion:version},humanoid:{getNormalizedBoneNode:n=>nodes.get(n)},expressionManager:{getValue:n=>values.get(n)??0,setValue:(n,v)=>values.set(n,v)},lookAt:{yaw:0,pitch:0,reset(){this.yaw=this.pitch=0;}}};
}
const face=(head={x:0,y:0,z:0},eye={l:1,r:1})=>({head,eye,pupil:{x:0,y:0},mouth:{shape:{A:0,I:0,E:0,O:0,U:0}}});
test('VRM1 旋转等于完整基变换，保留 VRM0 与所有 Euler 顺序',()=>{
 const c=new Quaternion().setFromAxisAngle(new Vector3(0,1,0),Math.PI);
 for(const order of ['XYZ','YXZ','ZXY'])for(const r of [{x:.4,y:-.3,z:.7},{x:-.8,y:1.2,z:-.4}]){
  const old=new Quaternion().setFromEuler(new Euler(r.x,r.y,r.z,order));
  const expected=c.clone().multiply(old).multiply(c.clone().invert());
  assert.ok(rotationQuaternion({...r,rotationOrder:order},'1').angleTo(expected)<1e-7);
  assert.ok(rotationQuaternion({...r,rotationOrder:order},'0').angleTo(old)<1e-7);
  assert.ok(old.angleTo(expected)>.5,'旧版直接赋值在相同动作上产生明显方向误差');
 }
});
test('30/60/120 Hz 收敛一致，并在推理两帧之间持续移动',()=>{
 const ends=[];
 for(const hz of [30,60,120]){
  const v=avatar(),m=new AvatarMotion(v);m.accept({face:face({x:.5,y:.2,z:.1})},0);
  const first=v.nodes.get('neck').quaternion.clone();m.tick(1/hz,1000/hz,true);
  assert.ok(first.angleTo(v.nodes.get('neck').quaternion)>0);
  const second=v.nodes.get('neck').quaternion.clone();m.tick(1/hz,2000/hz,true);
  assert.ok(second.angleTo(v.nodes.get('neck').quaternion)>0);
  for(let i=2;i<hz;i++)m.tick(1/hz,i*1000/hz,true);
  ends.push(v.nodes.get('neck').quaternion.clone());
 }
 assert.ok(ends[0].angleTo(ends[1])<1e-7);assert.ok(ends[1].angleTo(ends[2])<1e-7);
});
test('重复噪声被抑制，新的目标不会把骨架重置到中性',()=>{
 const v=avatar(),m=new AvatarMotion(v),values=[];
 for(let i=0;i<180;i++){
  m.accept({face:face({x:.2+(i%2?.04:-.04),y:0,z:0})},i*1000/60);
  m.tick(1/60,i*1000/60);if(i>60)values.push(new Euler().setFromQuaternion(v.nodes.get('neck').quaternion).x);
 }
 assert.ok(Math.max(...values)-Math.min(...values)<.02,'原始角度抖动峰峰值为 .08 rad');
 const before=v.nodes.get('neck').quaternion.clone();m.accept({face:face({x:.4,y:0,z:0})},3000);
 assert.ok(before.angleTo(v.nodes.get('neck').quaternion)<1e-7,'accept 只更新目标');
});
test('头身同时转向不重复叠加，公共眨眼与单眼闭合可用',()=>{
 const v=avatar(),m=new AvatarMotion(v);
 m.accept({face:face({x:0,y:.5,z:0},{l:0,r:0}),pose:{Hips:{rotation:{x:0,y:.5,z:0},position:{x:0,y:0,z:0}},Spine:{x:0,y:.5,z:0}}},0);
 for(let i=0;i<120;i++)m.tick(1/60,i*1000/60,true);
 assert.ok(v.nodes.get('neck').quaternion.angleTo(new Quaternion())<1e-7);
 assert.ok(v.nodes.get('neck').getWorldQuaternion(new Quaternion()).angleTo(rotationQuaternion({x:0,y:.5,z:0}))<1e-7);
 m.tick(.3,100);assert.ok(v.expressionManager.getValue('blink')>.99);
 m.accept({face:face({x:0,y:0,z:0},{l:0,r:1})},100);m.tick(.3,150);
 assert.ok(v.expressionManager.getValue('blinkLeft')>.99);assert.equal(v.expressionManager.getValue('blinkRight'),0);
});
test('短遮挡保持，长失踪衰减，主动停止立即回中性且丢掉校准',()=>{
 const v=avatar(),m=new AvatarMotion(v);m.accept({face:face({x:.4,y:0,z:0})},0);m.tick(.2,200);
 const before=v.nodes.get('neck').quaternion.clone();m.accept({face:null},220);m.tick(.02,230);
 assert.ok(v.nodes.get('neck').quaternion.angleTo(new Quaternion())>=before.angleTo(new Quaternion()));
 for(let i=0;i<60;i++)m.tick(1/60,300+i*1000/60);
 assert.ok(v.nodes.get('neck').quaternion.angleTo(new Quaternion())<.001);
 m.accept({face:face({x:.4,y:0,z:0})},1500);m.tick(.1,1510);m.reset();
 assert.equal(v.nodes.get('neck').quaternion.angleTo(new Quaternion()),0);assert.equal(m.seen.size,0);assert.deepEqual(v.nodes.get('hips').position.toArray(),[0,1,0]);
});
test('不可见腿部不使用猜测旋转，手部绑定转换到 VRM1',()=>{
 const v=avatar(),m=new AvatarMotion(v);
 m.accept({pose:{Hips:{rotation:{x:0,y:0,z:0},position:{x:0,y:0,z:0}},Spine:{x:0,y:0,z:0},LeftUpperLeg:{x:1,y:0,z:0}},visible:{LeftLeg:false},hands:{Left:{LeftWrist:{x:.3,y:0,z:.2},LeftIndexProximal:{x:0,y:0,z:.7}}}},0);
 assert.equal(m.seen.has('LeftLeg'),false);
 assert.ok(m.bones.get('LeftIndexProximal').target.angleTo(rotationQuaternion({x:0,y:0,z:.7}))<1e-7);
});
test('裁切髋部不能驱动根骨；估计深度突变不产生前后漂移',()=>{
 const v=avatar(),m=new AvatarMotion(v);
 const pose={Hips:{rotation:{x:0,y:2.8,z:1},worldPosition:{x:100,y:20,z:-100}},Spine:{x:0,y:.3,z:.1}};
 for(let i=0;i<60;i++){
  m.accept({pose,visible:{hips:false,torso:true}},i*33);m.tick(.033,i*33);
 }
 assert.equal(m.seen.has('body'),false);assert.ok(v.nodes.get('hips').quaternion.angleTo(new Quaternion())<1e-7);
 assert.deepEqual(v.nodes.get('hips').position.toArray(),[0,1,0]);
 m.accept({pose,visible:{hips:true,torso:true}},2100);m.tick(.033,2100);
 assert.equal(v.nodes.get('hips').position.x,0);assert.equal(v.nodes.get('hips').position.z,0);
});
test('真实父子层级下胸部和头臂方向不被髋部重复旋转',()=>{
 const v=avatar(),m=new AvatarMotion(v),arm={x:.1,y:.2,z:1};
 m.accept({face:face({x:.2,y:.3,z:.1}),pose:{Hips:{rotation:{x:0,y:.6,z:.2}},Spine:{x:0,y:.4,z:.15},LeftUpperArm:arm}},0);
 for(let i=0;i<180;i++)m.tick(1/60,i*1000/60,true);
 assert.ok(v.nodes.get('leftUpperArm').getWorldQuaternion(new Quaternion()).angleTo(rotationQuaternion(arm))<1e-6);
 assert.ok(v.nodes.get('neck').getWorldQuaternion(new Quaternion()).angleTo(rotationQuaternion({x:.2,y:.3,z:.08}))<1e-6);
});
test('半身版即使接收到全身姿态也固定髋部、腿部和人物中心',()=>{
 const v=avatar(),m=new AvatarMotion(v),rest=v.nodes.get('hips').position.clone();
 const pose={Hips:{rotation:{x:1,y:2,z:1},worldPosition:{x:30,y:-5,z:10}},Spine:{x:0,y:0,z:0}};
 for(const side of ['Left','Right']){pose[side+'UpperLeg']={x:.6,y:0,z:0};pose[side+'LowerLeg']={x:-1.2,y:0,z:0};}
 for(let i=0;i<1800;i++){m.accept({pose},i*1000/60);m.tick(1/60,i*1000/60);}
 assert.deepEqual(v.nodes.get('hips').position.toArray(),rest.toArray());
 for(const name of ['hips','leftUpperLeg','rightUpperLeg','leftLowerLeg','rightLowerLeg'])assert.ok(v.nodes.get(name).quaternion.angleTo(new Quaternion())<1e-7);
});
test('无效旋转不转成零角；同组其他骨更新不会永久保留坏骨',()=>{
 const v=avatar(),m=new AvatarMotion(v);
 m.target('LeftUpperArm',{x:0,y:0,z:1},0);m.tick(.1,100);
 m.target('LeftUpperArm',{x:NaN,y:0,z:0},200);
 assert.equal(m.bones.get('LeftUpperArm').time,0);
 for(let i=0;i<120;i++){const t=300+i*1000/60;m.target('LeftLowerArm',{x:0,y:0,z:.2},t);m.tick(1/60,t);}
 assert.ok(v.nodes.get('leftUpperArm').quaternion.angleTo(m.bones.get('LeftUpperArm').rest)<1e-5);
});

test('待机闭嘴、手势归中，呼吸不改变人物中心',()=>{
 const v=avatar(),m=new AvatarMotion(v),f=face();f.mouth.shape.A=1;
 m.accept({face:f,hands:{Left:{LeftIndexProximal:{x:0,y:0,z:1}}}},0);m.tick(.2,100);
 for(let i=0;i<180;i++)m.tick(1/60,1000+i*1000/60,false,true);
 assert.ok(v.expressionManager.getValue('aa')<.001);
 assert.ok(v.nodes.get('leftIndexProximal').quaternion.angleTo(new Quaternion())<.001);
 assert.deepEqual(v.nodes.get('hips').position.toArray(),[0,1,0]);
 assert.ok(v.nodes.get('upperChest').quaternion.angleTo(new Quaternion())<=.0081);
});
