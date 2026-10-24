// 本文件的目的：验证半身入画、无人待机、五种口型与掌面；全为构造数值，无相机访问。
import test from 'node:test';import assert from 'node:assert/strict';
import {Vector3,Quaternion} from 'three';
import {mouthShape,framing,Presence,palmBasis,handBasis} from '../src/signals.mjs';
import {solve} from '../src/rig.mjs';
function face(width=.12,gap=0){
 const p=Array.from({length:478},()=>({x:.5,y:.5,z:0}));
 p[33].x=.4;p[263].x=.6;p[61].x=.5-width/2;p[291].x=.5+width/2;
 p[13].y=.5-gap/2;p[14].y=.5+gap/2;return p;
}
test('闭嘴为零，A/E/I/O/U 均可达到可见幅度，总权重有界',()=>{
 assert.deepEqual(mouthShape(face(.12,0),640,480),{A:0,I:0,E:0,O:0,U:0});
 const shapes=[mouthShape(face(.105,.07),640,480),mouthShape(face(.145,.05),640,480),mouthShape(face(.145,.025),640,480),mouthShape(face(.065,.07),640,480),mouthShape(face(.065,.005),640,480)];
 for(const [i,k] of ['A','E','I','O','U'].entries())assert.ok(shapes[i][k]>.15,`${k}: ${shapes[i][k]}`);
 for(const shape of shapes){assert.ok(Object.values(shape).every(n=>Number.isFinite(n)&&n>=0&&n<=1));assert.ok(Object.values(shape).reduce((a,b)=>a+b,0)<=1.000001);}
});
test('同一张脸的不同输入宽高比不改变口型',()=>{
 const p=face(.12,.045),q=p.map(v=>({...v,y:v.y*.75}));
 const a=mouthShape(p,640,480),b=mouthShape(q,640,640);
 for(const k of Object.keys(a))assert.ok(Math.abs(a[k]-b[k])<1e-10);
});
test('半身入画不要求髋腿；面部裁切、缺肘和缺手分别报告',()=>{
 const f=face(),p=Array.from({length:33},()=>({x:.5,y:.5,z:0,visibility:1})),visible={torso:true,hips:false,LeftLeg:false,RightLeg:false};
 let frame=framing(f,p,visible,{});assert.equal(frame.upperComplete,true);assert.equal(frame.fullComplete,false);assert.equal(frame.hands,0);
 f[10].y=-.1;frame=framing(f,p,visible,{});assert.equal(frame.face,true);assert.equal(frame.faceComplete,false);assert.equal(frame.upperComplete,false);
 f[10].y=.5;p[13].visibility=.1;assert.equal(framing(f,p,visible,{}).upperComplete,false);
 assert.equal(framing(null,null,null,{}).person,false);
 f[10].y=.5;p[13].visibility=1;
 assert.equal(framing(f,p,{...visible,hips:true,LeftLeg:true,RightLeg:true,LeftArm:false,RightArm:true},{}).fullComplete,false);
});
test('短暂丢失不会闪烁；700 ms 后待机；过期推理也不能永久显示有人',()=>{
 const p=new Presence();assert.equal(p.state(0).idle,true);
 p.update({person:true,upperComplete:true},100);p.update({person:false},200);
 assert.equal(p.state(700).idle,false);assert.equal(p.state(801).idle,true);
 p.update({person:true},900);assert.equal(p.state(950).idle,false);assert.equal(p.state(1700).idle,true);
 assert.equal(p.state(1700,true).idle,false);p.reset();assert.equal(p.state(1700,true).idle,true);
});
test('掌面可完整翻转而非仅转动 0.3 rad；退化点被拒绝',()=>{
 const points=[new Vector3(0,0,0),new Vector3(1,0,0),new Vector3(1,1,0),new Vector3(1,-1,0)];
 const a=palmBasis(...points),turn=new Quaternion().setFromAxisAngle(new Vector3(1,0,0),Math.PI);
 const b=palmBasis(...points.map(p=>p.clone().applyQuaternion(turn)));
 assert.ok(a.angleTo(b)>3.14);assert.equal(palmBasis(...Array.from({length:4},()=>new Vector3())),null);
 assert.equal(handBasis(null,640,480),null);
});
test('半身适配不再输出腿驱动；坏手掌不会把手指转成默认姿势',()=>{
 const result=solve({leftHandLandmarks:Array.from({length:21},()=>({x:.5,y:.5,z:0}))},640,480);
 assert.deepEqual(result.hands,{});assert.equal(result.framing.person,false);
});
test('手指空间方向保留张开分量，且宽高比转换不压扁手势',()=>{
 const hand=Array.from({length:21},()=>({x:.5,y:.8,z:0}));
 for(const [start,x] of [[5,.42],[9,.5],[13,.58],[17,.65]])for(let j=0;j<4;j++)hand[start+j]={x:x+(start===5?-.02*j:0),y:.55-.07*j,z:-.01*j};
 for(let i=1;i<5;i++)hand[i]={x:.5-.04*i,y:.8-.04*i,z:0};
 const a=solve({rightHandLandmarks:hand},640,480);
 const b=solve({rightHandLandmarks:hand.map(p=>({...p,y:p.y*.75}))},640,640);
 assert.ok(a.fingerDirections.LeftIndexProximal[0]>.2);
 for(const key of Object.keys(a.fingerDirections))for(let i=0;i<3;i++)assert.ok(Math.abs(a.fingerDirections[key][i]-b.fingerDirections[key][i])<1e-9);
 assert.equal(Object.keys(a.fingerDirections).length,15);
});
