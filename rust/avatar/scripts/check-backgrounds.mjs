// 本文件的目的：真实浏览器验证组合像素、静音媒体、导入路由和失效帧；不打开媒体设备。
import {chromium} from 'playwright-core';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {writeFile} from 'node:fs/promises';
import {startServer} from './server.mjs';
const camera={status:async()=>({installed:false,targetLabel:'memory-test'}),stop:async()=>true};
const sample=fileURLToPath(new URL('../backgrounds/aurora.mp4',import.meta.url));
const server=await startServer(0,{camera,backgroundFile:sample}),origin=`http://127.0.0.1:${server.address().port}`;
let browser;const checks=[];
try{
 const first=await fetch(origin+'/background/custom',{headers:{Range:'bytes=0-31'}});
 assert.equal(first.status,206);assert.equal((await first.arrayBuffer()).byteLength,32);
 assert.equal((await fetch(origin+'/background/custom',{headers:{Range:'bytes=999999999-'}})).status,416);
 assert.equal((await fetch(origin+'/background/custom',{headers:{Origin:'https://example.com'}})).status,403);
 const bundled=await fetch(origin+'/backgrounds/aurora.mp4',{headers:{Range:'bytes=0-1'}});assert.equal(bundled.status,206);assert.equal((await bundled.arrayBuffer()).byteLength,2);
 assert.equal((await fetch(origin+'/background/../../etc/passwd')).status,404);checks.push('自定义素材仅固定路径，支持有界 Range，拒绝越界和目录访问');
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 for(const background of ['original','plate','sample','parallax','custom']){
  const context=await browser.newContext({viewport:{width:800,height:700},permissions:[]});
  await context.route('**/*',r=>r.request().url().startsWith(origin+'/')?r.continue():r.abort());
  await context.addInitScript(background=>{window.callbridgeComposition={person:'none',background};window.cameraCalls=0;navigator.mediaDevices.getUserMedia=()=>{window.cameraCalls++;throw Error('禁止设备采集');};},background);
  const page=await context.newPage();await page.goto(origin);await page.waitForFunction(()=>window.avatarLab?.stats.ready,{},{timeout:30000});
  assert.equal(await page.evaluate(()=>Boolean(avatarLab.vrm)),false);assert.equal(await page.evaluate(()=>cameraCalls),0);
  if(background==='original'){
   // 用持续变色的内存画布代替相机；验证实时直通不等 Holistic，且从不请求音频。
   await page.evaluate(()=>{
    const c=document.createElement('canvas');c.width=320;c.height=240;const x=c.getContext('2d');
    window.liveTest={color:'#ff00ff',running:true,c};
    const draw=()=>{x.fillStyle=liveTest.color;x.fillRect(0,0,320,240);if(liveTest.running)requestAnimationFrame(draw);};draw();
    navigator.mediaDevices.getUserMedia=async constraints=>{window.cameraCalls++;liveTest.constraints=constraints;liveTest.stream=c.captureStream(30);return liveTest.stream;};
   });
   await page.click('#camera');await page.waitForFunction(()=>avatarLab.stats.camera);
   const color=rgb=>page.waitForFunction(rgb=>{const c=document.querySelector('#output'),p=c.getContext('2d').getImageData(c.width/2,c.height/2,1,1).data;return rgb.every((v,i)=>Math.abs(v-p[i])<5);},rgb);
   await color([255,0,255]);await page.evaluate(()=>liveTest.color='#00ffff');await color([0,255,255]);
   assert.equal(await page.evaluate(()=>liveTest.constraints.audio),false);
   assert.equal(await page.evaluate(()=>avatarLab.stats.inferences),0);
   assert.equal(await page.evaluate(()=>typeof window.Holistic),'undefined');
   assert.equal(await page.locator('#capture-background').isVisible(),false);
   await page.click('#stop');
   assert.equal(await page.evaluate(()=>liveTest.stream.getTracks().every(t=>t.readyState==='ended')),true);
   assert.equal(await page.evaluate(()=>avatarLab.stats.camera),false);
   const cleared=await page.evaluate(()=>{const c=document.querySelector('#output');return Array.from(c.getContext('2d').getImageData(c.width/2,c.height/2,1,1).data).slice(0,3);});
   assert.notDeepEqual(cleared,[0,255,255]);
   await page.evaluate(()=>{liveTest.running=false;navigator.mediaDevices.getUserMedia=()=>new Promise(resolve=>{liveTest.resolve=resolve;});});
   await page.click('#camera');await page.waitForFunction(()=>Boolean(liveTest.resolve));await page.click('#stop');
   await page.evaluate(()=>{liveTest.late=liveTest.c.captureStream(30);liveTest.resolve(liveTest.late);});
   await page.waitForFunction(()=>liveTest.late.getTracks().every(t=>t.readyState==='ended'));
   assert.equal(await page.evaluate(()=>avatarLab.stats.camera),false);
   checks.push('现场画面持续更新，不加载跟踪模型或请求声音；停止清帧、释放视频及拒绝迟到授权');
  }
  if(['sample','custom'].includes(background)){
   await page.click('#demo');await page.waitForFunction(()=>avatarLab.backgroundSource.video.currentTime>.2);
   assert.equal(await page.evaluate(()=>{const v=avatarLab.backgroundSource.video;return v.muted&&v.defaultMuted&&v.volume===0&&v.loop;}),true);
   await page.click('#stop');assert.equal(await page.evaluate(()=>avatarLab.backgroundSource.video.paused),true);
  }
  if(background==='parallax'){
   const changed=await page.evaluate(()=>{const c=document.querySelector('#output'),ctx=c.getContext('2d'),b=avatarLab.backgroundSource;
    b.draw(ctx,c.width,c.height,0,0);const a=c.toDataURL();b.draw(ctx,c.width,c.height,1000,.8);return a!==c.toDataURL();});
   assert.ok(changed);await page.locator('#output').screenshot({path:fileURLToPath(new URL('../../build/background-parallax.png',import.meta.url))});
  }
  // 使用同帧红色背景、洋红人物和分割 alpha，分别核对 10 种组合，过期后不泄露原场景。
  const result=await page.evaluate(()=>{
   const r=avatarLab.replacement;const make=(color)=>{const c=document.createElement('canvas');c.width=c.height=100;const x=c.getContext('2d');if(color){x.fillStyle=color;x.fillRect(0,0,100,100);}return c;};
   const frame=make('#ff0000');frame.getContext('2d').fillStyle='#ff00ff';frame.getContext('2d').fillRect(40,40,20,20);
   const mask=make();mask.getContext('2d').fillRect(40,40,20,20);const avatar=make();avatar.getContext('2d').fillStyle='#ff9900';avatar.getContext('2d').fillRect(70,70,10,10);
   r.reset();r.candidate.width=r.candidate.height=100;r.candidate.getContext('2d').fillStyle='#00ff00';r.candidate.getContext('2d').fillRect(0,0,100,100);r.capture.state='review';r.confirm();r.accept(frame,mask,{},1000);
   r.output.width=r.output.height=100;const source={draw:(ctx,w,h)=>{ctx.fillStyle='#0000ff';ctx.fillRect(0,0,w,h);}},read=(x,y)=>Array.from(r.output.getContext('2d').getImageData(x,y,1,1).data).slice(0,3);
   const rows=[];for(const person of ['none','avatar'])for(const background of ['original','plate','sample','parallax','custom']){
    r.draw(avatar,1001,{person,background,source});rows.push({person,background,edge:read(5,5),human:read(50,50),avatar:read(75,75)});
   }
   r.draw(avatar,1300,{person:'none',background:'sample',source});return {rows,stale:read(50,50)};
  });
  for(const row of result.rows){const expected=row.background==='original'&&row.person==='none'?[255,0,0]:['original','plate'].includes(row.background)?[0,255,0]:[0,0,255];assert.deepEqual(row.edge,expected);
   if(row.person==='none')assert.deepEqual(row.human,[255,0,255]);else {assert.notDeepEqual(row.human,[255,0,255]);assert.deepEqual(row.avatar,[255,153,0]);}}
  assert.deepEqual(result.stale,[0,0,255]);checks.push(background+'：加载、无 VRM/设备、组合像素与过期保护通过');await context.close();
 }
 // 超限素材不能悄悄卡在未就绪，也不能因精简提示而隐藏具体失败原因。
 const invalid=await browser.newContext({permissions:[]});
 await invalid.route('**/*',r=>r.request().url().startsWith(origin+'/')?r.continue():r.abort());
 await invalid.addInitScript(()=>{window.callbridgeComposition={person:'none',background:'sample'};Object.defineProperty(HTMLMediaElement.prototype,'duration',{get:()=>121});navigator.mediaDevices.getUserMedia=()=>{throw Error('禁止设备采集');};});
 const bad=await invalid.newPage();await bad.goto(origin);
 await bad.waitForFunction(()=>!document.querySelector('#status').hidden&&document.querySelector('#status').textContent.includes('120 秒'));
 assert.equal(await bad.evaluate(()=>avatarLab.stats.ready),false);
 assert.equal(await bad.evaluate(()=>avatarLab.backgroundSource.video.paused),true);
 checks.push('超限媒体显示明确错误，保持未就绪并暂停');await invalid.close();
 await writeFile(fileURLToPath(new URL('../../build/background-check.json',import.meta.url)),JSON.stringify({passed:true,checks,mediaIO:false},null,2));console.log(JSON.stringify({passed:true,checks}));
}finally{await browser?.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
