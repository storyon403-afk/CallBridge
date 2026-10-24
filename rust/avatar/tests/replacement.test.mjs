// 本文件的目的：验证离场确认和人物移除边界；不用真人相机或真实图像。
import test from 'node:test';
import assert from 'node:assert/strict';
import {BackgroundCapture,removalMask} from '../src/replacement.mjs';
test('空背景经过倒计时、连续无人检测与显式确认才能使用',()=>{
 const c=new BackgroundCapture();assert.equal(c.confirm(),false);c.begin(0);
 for(const t of [4000,4250,4500,4750])assert.equal(c.observe(t,false),false);
 assert.equal(c.observe(5000,false),true);assert.equal(c.state,'review');
 assert.equal(c.observe(6000,false),false);assert.equal(c.confirm(),true);assert.equal(c.state,'ready');
 c.reset();assert.equal(c.confirm(),false);
});
test('出现人物重置连续无人窗口，超时不自动采集',()=>{
 const c=new BackgroundCapture();c.begin(0);c.observe(4000,false);c.observe(4800,true);
 for(const t of [5000,5200,5400,5600])assert.equal(c.observe(t,false),false);
 assert.equal(c.observe(6000,false),true);
 c.begin(0);assert.equal(c.observe(16000,false),false);assert.equal(c.state,'timeout');assert.equal(c.confirm(),false);
});
test('检测中断和重复时间不能凑成连续无人窗口',()=>{
 const c=new BackgroundCapture();c.begin(0);
 for(const t of [4000,4250,4500,4750])c.observe(t,false);
 assert.equal(c.observe(5500,false),false);
 for(let i=0;i<5;i++)assert.equal(c.observe(5500,false),false);
 assert.equal(c.frames,1);assert.equal(c.observe(NaN,false),false);
 for(const t of [5750,6000,6250])assert.equal(c.observe(t,false),false);
 assert.equal(c.observe(6500,false),true);
});
test('遮罩按 alpha 去除人物，扩大三像素而不是把 RGB 颜色当置信度',()=>{
 const p=new Uint8ClampedArray(11*11*4);p.fill(255);
 for(let i=3;i<p.length;i+=4)p[i]=0;
 p[(5*11+5)*4+3]=13;
 const m=removalMask(p,11,11);assert.equal(m.fraction,1/121);
 assert.equal(m.pixels.filter((v,i)=>i%4===3&&v===255).length,49);
 assert.equal(m.pixels[3],0);
});
test('全空、全满和边缘遮罩有界，非法尺寸拒绝',()=>{
 const p=new Uint8ClampedArray(4*4*4);assert.equal(removalMask(p,4,4).fraction,0);
 p[3]=255;assert.equal(removalMask(p,4,4,1).pixels.filter((v,i)=>i%4===3&&v).length,4);
 p.fill(255);assert.equal(removalMask(p,4,4).fraction,1);
 assert.throws(()=>removalMask(p,0,4));assert.throws(()=>removalMask(p,320,241));assert.throws(()=>removalMask(p,4,4,9));
});
