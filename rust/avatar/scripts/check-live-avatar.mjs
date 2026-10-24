// 本文件的目的：用公开图和连续变色的合成视频验证无离场采集的现场背景＋虚拟人物。
// 设备请求全部替换为内存画布，不开启真实摄像头、麦克风或虚拟设备。
import {chromium} from 'playwright-core';
import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {startServer} from './server.mjs';
const server=await startServer(0,{camera:{status:async()=>({installed:false}),stop:async()=>true}}),origin=`http://127.0.0.1:${server.address().port}`;
let browser;const errors=[];
try{
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const context=await browser.newContext({viewport:{width:1000,height:900},permissions:[]});
 await context.route('**/*',r=>r.request().url().startsWith(origin+'/')?r.continue():r.abort());
 await context.addInitScript(()=>{window.callbridgeComposition={person:'avatar',background:'original'};navigator.mediaDevices.getUserMedia=()=>{throw Error('未允许设备访问');};});
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));await page.goto(origin);await page.waitForFunction(()=>avatarLab.stats.ready);
 assert.equal(await page.locator('#capture-background').isVisible(),false);
 await page.evaluate(async()=>{
  const image=new Image();image.src='fixtures/pose.jpg';await image.decode();
  const c=document.createElement('canvas');c.width=640;c.height=480;const x=c.getContext('2d');window.testLive={color:'#2244ee',running:true};
  const draw=()=>{x.fillStyle=testLive.color;x.fillRect(0,0,640,480);x.drawImage(image,160,0,320,480);if(testLive.running)requestAnimationFrame(draw);};draw();
  navigator.mediaDevices.getUserMedia=async constraints=>{testLive.constraints=constraints;testLive.stream=c.captureStream(30);return testLive.stream;};
 });
 await page.click('#camera');await page.waitForFunction(()=>avatarLab.stats.camera&&avatarLab.replacement.state(performance.now()).live,{},{timeout:60000});
 const matches=rgb=>page.waitForFunction(rgb=>{const c=document.querySelector('#output'),p=c.getContext('2d').getImageData(10,c.height/2,1,1).data;return rgb.every((v,i)=>Math.abs(v-p[i])<5);},rgb,{timeout:30000});
 await matches([34,68,238]);await page.evaluate(()=>testLive.color='#42c583');await matches([66,197,131]);
 assert.equal(await page.evaluate(()=>avatarLab.replacement.hasPlate),false);assert.equal(await page.evaluate(()=>testLive.constraints.audio),false);
 assert.equal(await page.evaluate(()=>Boolean(avatarLab.vrm)),true);
 await page.locator('#output').screenshot({path:fileURLToPath(new URL('../../build/live-avatar-preview.png',import.meta.url))});
 const state=await page.evaluate(()=>({inferences:avatarLab.stats.inferences,latencyMs:avatarLab.stats.latencyMs.at(-1),state:avatarLab.replacement.state(performance.now())}));
 await page.click('#stop');
 assert.equal(await page.evaluate(()=>testLive.stream.getTracks().every(t=>t.readyState==='ended')),true);
 assert.equal(await page.evaluate(()=>avatarLab.replacement.liveValid),false);
 await page.evaluate(()=>testLive.running=false);
 // 稳定像素检查：无脸/肩点仍可用分割，慢推理刚发布时可显示，过期/缺遮罩则不泄露旧现场。
 const pixels=await page.evaluate(()=>{
  const make=color=>{const c=document.createElement('canvas');c.width=80;c.height=60;const x=c.getContext('2d');if(color){x.fillStyle=color;x.fillRect(0,0,80,60);}return c;};
  const r=avatarLab.replacement,frame=make('#00ff00'),mask=make(),avatar=make();
  frame.getContext('2d').fillStyle='#ff0000';frame.getContext('2d').fillRect(30,20,20,30);mask.getContext('2d').fillRect(30,20,20,30);
  const x=avatar.getContext('2d');x.fillStyle='#0000ff';x.fillRect(35,25,10,10);r.reset();r.output.width=80;r.output.height=60;
  const read=(x,y)=>Array.from(r.output.getContext('2d').getImageData(x,y,1,1).data).slice(0,3);
  r.accept(frame,mask,{},1400,1000);r.draw(avatar,1401);const first={edge:read(5,5),hole:read(50,40),avatar:read(40,30),ready:r.state(1401).live};
  r.draw(avatar,1700);const stale=read(5,5);r.accept(frame,null,{},1800,1790);r.draw(avatar,1801);return {first,stale,missing:read(5,5)};
 });
 assert.deepEqual(pixels.first.edge,[0,255,0]);assert.deepEqual(pixels.first.hole,[0,255,0]);assert.deepEqual(pixels.first.avatar,[0,0,255]);assert.equal(pixels.first.ready,true);
 assert.notDeepEqual(pixels.stale,[0,255,0]);assert.notDeepEqual(pixels.missing,[0,255,0]);assert.deepEqual(errors,[]);
 const report={passed:true,state,pixels,physicalCamera:false,microphone:false,virtualDevice:false,errors};
 await writeFile(fileURLToPath(new URL('../../build/live-avatar-check.json',import.meta.url)),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await browser?.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
