// 本文件的目的：用固定噪声、异常跳点和遮挡序列验证稳定性；不采集个人图像。
import test from 'node:test';
import assert from 'node:assert/strict';
import {Quaternion,Vector3} from 'three';
import {RotationFilter} from '../src/rotation-filter.mjs';
import {poseVisibility,solve} from '../src/rig.mjs';
const q=a=>new Quaternion().setFromAxisAngle(new Vector3(0,1,0),a);
function landmarks(){
 const image=Array.from({length:33},()=>({x:.5,y:.5,z:0,visibility:1}));
 const world=Array.from({length:33},(_,i)=>({x:(i%2?-.2:.2),y:i/40-.5,z:.02*(i%3),visibility:1}));
 return {image,world};
}
test('世界置信度、出画髋部和退化骨段分别阻断相应部位',()=>{
 const {image,world}=landmarks();assert.equal(poseVisibility(image,world).hips,true);
 image[23].y=1.1;let v=poseVisibility(image,world);
 assert.equal(v.hips,false);assert.equal(v.RightLeg,false);assert.equal(v.torso,true);assert.equal(v.RightArm,true);
 world[15].visibility=.1;assert.equal(poseVisibility(image,world).RightArm,false);
 world[13]={...world[11]};world[15].visibility=1;assert.equal(poseVisibility(image,world).RightArm,false);
});
test('可见的下垂手臂不因手腕世界高度跨 0.1m 而突然归零',()=>{
 const {image,world}=landmarks();
 world[15].y=.099;const a=solve({poseLandmarks:image,poseWorldLandmarks:world},640,480);
 world[15].y=.101;const b=solve({poseLandmarks:image,poseWorldLandmarks:world},640,480);
 assert.equal(a.visible.RightArm,true);assert.equal(b.visible.RightArm,true);
 assert.ok(Math.abs(a.pose.RightUpperArm.z-b.pose.RightUpperArm.z)<.02);
 assert.ok(Math.abs(b.pose.RightLowerArm.y)>.01);
});
test('1€ 保留单位四元数，跨 ±π 和 q/-q 不绕远路',()=>{
 const f=new RotationFilter();f.sample(q(Math.PI-.02),0);
 const r=f.sample(q(-Math.PI+.02),33);
 assert.ok(r.angleTo(q(Math.PI))<.025);assert.ok(Math.abs(r.length()-1)<1e-9);
 const negative=q(-Math.PI+.02);negative.set(...negative.toArray().map(x=>-x));
 assert.ok(f.sample(negative,66).angleTo(q(Math.PI))<.025);
 assert.equal(f.sample(q(0),66),null);
});
test('静止噪声衰减与快速转身延迟分别设门槛',()=>{
 const f=new RotationFilter(),angles=[];
 for(let i=0;i<120;i++){const r=f.sample(q(i%2?.04:-.04),i*1000/30);if(i>30)angles.push(2*Math.atan2(r.y,r.w));}
 const noise=Math.max(...angles)-Math.min(...angles);assert.ok(noise<.018,`噪声峰峰值 ${noise}`);
 let reached=null;
 for(let i=0;i<30;i++){const t=4000+i*1000/30,r=f.sample(q(.8),t);if(r&&r.angleTo(q(.8))<.08&&reached===null)reached=t-4000;}
 assert.ok(reached!==null&&reached<=200,`到 90% 的延迟 ${reached} ms`);
});
test('单帧翻转拒绝、持续动作确认、长遮挡重新捕获',()=>{
 const f=new RotationFilter();f.sample(q(0),0);
 assert.equal(f.sample(q(2.4),33),null);
 assert.ok(f.sample(q(.01),66).angleTo(q(0))<.01);
 assert.equal(f.sample(q(1.8),99),null);
 assert.ok(f.sample(q(1.81),132).angleTo(q(0))>.1);
 assert.ok(f.sample(q(-1),500).angleTo(q(-1))<1e-7);
 f.reset();assert.ok(f.sample(q(.5),0).angleTo(q(.5))<1e-7);
});
