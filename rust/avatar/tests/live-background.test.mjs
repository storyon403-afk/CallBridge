// 本文件的目的：验证补洞只传播背景颜色、内存边界及无可用背景时的失败行为。
import test from 'node:test';
import assert from 'node:assert/strict';
import {extendBackground} from '../src/live-background.mjs';
test('补洞不读取人物颜色，保留已知背景',()=>{
 const image=new Uint8ClampedArray([0,255,0,255,255,0,0,255,255,0,0,255]),mask=new Uint8ClampedArray(12);mask[7]=255;mask[11]=1;
 assert.deepEqual(Array.from(extendBackground(image,mask,3,1)),[0,255,0,255,0,255,0,255,0,255,0,255]);
});
test('全遮挡不放行人物，空遮挡保留背景',()=>{
 const image=new Uint8ClampedArray([20,30,40,255]);assert.equal(extendBackground(image,new Uint8ClampedArray([0,0,0,255]),1,1),null);
 assert.deepEqual(extendBackground(image,new Uint8ClampedArray(4),1,1),image);
});
test('补洞拒绝超限和不匹配的缓冲',()=>{
 assert.throws(()=>extendBackground(new Uint8ClampedArray(4),new Uint8ClampedArray(4),81,1));
 assert.throws(()=>extendBackground(new Uint8ClampedArray(4),new Uint8ClampedArray(4),1,61));
 assert.throws(()=>extendBackground(new Uint8ClampedArray(4),new Uint8ClampedArray(3),1,1));
});
