// 本文件的目的：验证本地角色和图片背景真实加载；设备接口由测试替身阻断。
import {chromium} from 'playwright-core';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {startServer} from './server.mjs';
const model=fileURLToPath(new URL('../../build/avatar/model/sample.vrm',import.meta.url));
const picture=fileURLToPath(new URL('../../../icon/app-icon.png',import.meta.url));
const data=await readFile(model);process.env.CB_CHARACTER_FILE=model;process.env.CB_CHARACTER_SHA=createHash('sha256').update(data).digest('hex');process.env.CB_CHARACTER_BYTES=String(data.length);
const camera={status:async()=>({available:false,active:false}),stop:async()=>true};
const server=await startServer(0,{camera,backgroundFile:picture});const origin=`http://127.0.0.1:${server.address().port}`;let browser;
try{
 assert.equal((await fetch(origin+'/character/info',{headers:{Origin:'https://example.com'}})).status,403);
 assert.equal(createHash('sha256').update(Buffer.from(await(await fetch(origin+'/character/model')).arrayBuffer())).digest('hex'),process.env.CB_CHARACTER_SHA);
 browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 for(const person of ['none','avatar']){
  const context=await browser.newContext({permissions:[]});const external=[];
  await context.route('**/*',r=>{if(r.request().url().startsWith(origin+'/'))return r.continue();external.push(r.request().url());return r.abort();});
  await context.addInitScript(person=>{window.callbridgeComposition={person,background:'image',character:true};window.mediaCalls=0;navigator.mediaDevices.getUserMedia=()=>{window.mediaCalls++;throw Error('No devices in test');};},person);
  const page=await context.newPage();await page.goto(origin);await page.waitForFunction(()=>window.avatarLab?.stats.ready,null,{timeout:60000});
  const state=await page.evaluate(()=>({image:!!avatarLab.backgroundSource.image,custom:avatarLab.stats.appearance?.custom??false,media:window.mediaCalls}));
  assert.equal(state.image,true);assert.equal(state.custom,person==='avatar');assert.equal(state.media,0);assert.deepEqual(external,[]);await context.close();
 }
 console.log('PASS image background, original VRM appearance, cross-origin refusal; no device IO');
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
