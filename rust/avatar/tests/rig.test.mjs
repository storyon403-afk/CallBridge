// 本文件的目的：验证停止/重启的代次、容量与坏关键点，全部为数值，无设备访问。
import test from 'node:test';import assert from 'node:assert/strict';
import {Gate,points,solve,bounded} from '../src/rig.mjs';
test('拒绝截断、NaN 和非法图像尺寸',()=>{
 assert.equal(points([{x:0,y:0,z:NaN}],1),null);assert.equal(points([],33),null);
 assert.throws(()=>solve({},0,480));assert.equal(bounded(Infinity),0);
 const empty=solve({},640,480);assert.equal(empty.face,null);assert.equal(empty.pose,null);assert.deepEqual(empty.hands,{});assert.equal(empty.framing.person,false);
});
test('给原地解算器传独立坐标副本',()=>{const src=[{x:.1,y:.2,z:.3}];const cloned=points(src,1);cloned[0].x=42;assert.equal(src[0].x,.1);});
test('只允许一个推理在途，停止后迟到结果不能应用于新会话',async()=>{
 const gate=new Gate(),old=gate.start();let release,published=0;
 const pending=gate.frame(old,()=>new Promise(r=>release=r),()=>published++);
 assert.equal(await gate.frame(old,()=>Promise.resolve(),()=>published++),false);
 gate.stop();const current=gate.start();release({});assert.equal(await pending,false);assert.equal(published,0);
 assert.equal(await gate.frame(current,()=>Promise.resolve({}),()=>published++),true);assert.equal(published,1);
});
test('异常释放在途闸门',async()=>{const g=new Gate(),e=g.start();await assert.rejects(g.frame(e,()=>Promise.reject(Error('test')),()=>{}));assert.equal(g.pending,false);});
