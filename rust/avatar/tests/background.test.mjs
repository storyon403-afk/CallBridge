// 本文件的目的：证明不同类别可以组合，同级人物槽不接受多个互斥方案。
import test from 'node:test';
import assert from 'node:assert/strict';
import {composition} from '../src/background.mjs';
test('人物与五类背景自由组合，不覆盖对方选择',()=>{
 for(const person of ['none','avatar'])for(const background of ['original','plate','sample','parallax','custom']){
  const value=composition({person,background});assert.deepEqual(value,{person,background});assert.ok(Object.isFrozen(value));
 }
});
test('同级多选和未实现的真人/重建方案不能启用',()=>{
 for(const person of [['avatar','real'],'real','unknown'])assert.throws(()=>composition({person}));
 for(const background of [['plate','sample'],'reconstruction','https://example.com'])assert.throws(()=>composition({background}));
});
