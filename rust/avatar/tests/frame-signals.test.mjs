// 合成可控嘴角/肩轴，验证表情含义、宽高比及旋转不变性，不依赖个人摄像头素材。
import test from 'node:test';import assert from 'node:assert/strict';
import {frameFaceSignals,frameShoulderTilt} from '../src/frame-signals.mjs';
const close=(a,b)=>assert.ok(Math.abs(a-b)<1e-9,`${a} != ${b}`);
function face({lift=0,gap=2,roll=0,yaw=0,width=640,height=480}={}){
 const f=Array.from({length:478},()=>({x:.5,y:.4,z:0}));
 const pts={33:[-50,0,0],133:[-20,0,0],159:[-35,-3,0],145:[-35,3,0],362:[20,0,0],263:[50,0,0],386:[35,-3,0],374:[35,3,0],152:[0,110,0],61:[-29,60-lift,0],291:[29,60-lift,0],13:[0,60-gap/2,0],14:[0,60+gap/2,0]};
 for(const [id,[x,y,z]] of Object.entries(pts)){
  const a=x*Math.cos(yaw)+z*Math.sin(yaw),c=-x*Math.sin(yaw)+z*Math.cos(yaw);
  f[id]={x:(width/2+a*Math.cos(roll)-y*Math.sin(roll))/width,y:(height*.35+a*Math.sin(roll)+y*Math.cos(roll))/height,z:c/width};
 }
 return f;
}
test('嘴角上扬识别微笑，张嘴本身不等于笑，嘴角下压触发不悦',()=>{
 const read=o=>frameFaceSignals(face(o),640,480);
 assert.equal(read({}).smile,0);assert.equal(read({}).frown,0);
 assert.ok(read({lift:4}).smile>.5);assert.ok(read({lift:13,gap:26}).smile>.5);
 const talking=read({gap:26});assert.ok(talking.open>.9);assert.equal(talking.smile,0);assert.equal(talking.frown,0);
 assert.ok(read({lift:-5}).frown>.55);
});
test('同一个表情在不同宽高比、歪头和转头下不变',()=>{
 const base=frameFaceSignals(face({lift:4}),640,480);
 for(const [width,height,roll,yaw] of [[1280,720,.4,.3],[480,640,-.5,-.4],[640,480,.7,0]]){
  const f=frameFaceSignals(face({lift:4,width,height,roll,yaw}),width,height);
  for(const key of ['smile','frown','open','cornerLift','mouthWidth','eyeLeft','eyeRight'])close(f[key],base[key]);
 }
});
test('坏面部点、退化眼轴和出画嘴角不输出表情',()=>{
 assert.equal(frameFaceSignals(null,640,480),null);
 const f=face();f[61].x=NaN;assert.equal(frameFaceSignals(f,640,480),null);
 f[61]={x:2,y:.5,z:0};assert.equal(frameFaceSignals(f,640,480),null);
 f[61]=face()[61];f[33]={...f[263]};assert.equal(frameFaceSignals(f,640,480),null);
});
test('肩轴与左右索引顺序无关，不可见/侧身肩膀不带歪角色',()=>{
 const p=Array.from({length:33},()=>({x:.5,y:.5,visibility:1}));
 p[11]={x:.3,y:.4,visibility:1};p[12]={x:.7,y:.4,visibility:1};close(frameShoulderTilt(p,640,480),0);
 p[12].y=.45;const angle=frameShoulderTilt(p,640,480);assert.ok(angle>0);
 [p[11],p[12]]=[p[12],p[11]];close(frameShoulderTilt(p,640,480),angle);
 p[11].visibility=.2;assert.equal(frameShoulderTilt(p,640,480),null);
 p[11].visibility=1;p[11].x=p[12].x+.01;assert.equal(frameShoulderTilt(p,640,480),null);
});
