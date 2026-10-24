// 本文件的目的：在用户单独授权后运行 30 秒真实摄像头检查，只保存数值，不保存图像。
// 新建浏览器上下文；浏览器许可只含 camera，macOS 的设备权限仍由系统决定。
import {chromium} from 'playwright-core';
import {mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {startServer} from './server.mjs';
if(process.argv.length!==3||process.argv[2]!=='--confirm-camera')throw Error('需要单独授权并传入 --confirm-camera；会开启真实摄像头约 30 秒。');
const out=fileURLToPath(new URL('../../build/avatar-check/',import.meta.url));
await mkdir(out,{recursive:true});
const server=await startServer(0),origin=`http://127.0.0.1:${server.address().port}`;
let browser,page;const errors=[],external=[];
const deadline=setTimeout(()=>browser?.close(),120000);deadline.unref();
try{
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:false});
 const context=await browser.newContext({viewport:{width:960,height:820}});
 await context.grantPermissions(['camera'],{origin});
 await context.route('**/*',route=>{const url=route.request().url();if(url.startsWith(origin+'/'))return route.continue();external.push(url);return route.abort();});
 page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
 await page.goto(origin);await page.waitForFunction(()=>window.avatarLab?.stats.ready,{},{timeout:60000});
 // 先以公开图片预热，避免把模型编译时间计为真人跟踪速度。
 await page.evaluate(()=>avatarLab.fixture());
 const baseline=await page.evaluate(()=>{avatarLab.stop();avatarLab.stats.latencyMs.length=0;return {...avatarLab.stats};});
 await page.bringToFront();await page.click('#camera');console.log('已请求摄像头，等待系统许可或设备启动；尚未计入 30 秒测试。');
 await page.waitForFunction(()=>avatarLab.stats.camera||avatarLab.stats.mode==='idle',{},{timeout:45000});
 if(!await page.evaluate(()=>avatarLab.stats.camera))throw Error(await page.locator('#status').innerText());
 // 提前保留 track 的状态引用；页面自主停止后 srcObject 会清空，不能再从中找轨道。
 await page.evaluate(()=>window.cameraCheckTracks=document.getElementById('input').srcObject.getTracks());
 const start=Date.now();console.log('真实摄像头已开启，30 秒后自动停止；请闭嘴/张嘴/圆唇，张掌/握拳，并短暂离开画面验证待机。');
 // 只统计 camera 模式；用户切到测试图时不能把公开图片的计数混进真人结果。
 const samples=[];let measured=await page.evaluate(()=>({...avatarLab.stats})),interrupted=false;
 while(Date.now()-start<30000){
  await page.waitForTimeout(500);
  const snapshot=await page.evaluate(()=>{const s=avatarLab.stats,m=avatarLab.motion;return {stats:{...s},sample:{camera:s.camera,mode:s.mode,face:s.face,pose:s.pose,hands:s.hands,inferences:s.inferences,renders:s.renders,tracked:s.tracked,framing:s.framing,presence:s.presence,
   finite:[...m.bones.values()].every(b=>b.node.quaternion.toArray().every(Number.isFinite)),
   rootXZDrift:Math.hypot(m.hips.position.x-m.restPosition.x,m.hips.position.z-m.restPosition.z),
   hidden:document.hidden,status:document.getElementById('status').textContent}};});
  if(!snapshot.sample.camera||snapshot.sample.mode!=='camera'){interrupted=true;break;}
  measured=snapshot.stats;samples.push(snapshot.sample);
 }
 // 保留 track 仅用于检查 readyState；停止后不再读取或复制帧。
 const stopped=await page.evaluate(()=>{const v=document.getElementById('input'),tracks=window.cameraCheckTracks??[];avatarLab.stop();const result={trackStates:tracks.map(t=>t.readyState),sourceCleared:v.srcObject===null,camera:avatarLab.stats.camera};delete window.cameraCheckTracks;return result;});
 const elapsedMs=Date.now()-start;
 const latencies=[...measured.latencyMs].sort((a,b)=>a-b);
 const report={passed:!interrupted&&samples.length>0&&samples.every(s=>s.finite&&s.rootXZDrift<1e-6)&&measured.inferences>baseline.inferences&&stopped.sourceCleared&&stopped.trackStates.length>0&&stopped.trackStates.every(s=>s==='ended')&&errors.length===0&&external.length===0,
  browserVersion:browser.version(),elapsedMs,completed30Seconds:!interrupted&&elapsedMs>=30000,interrupted,lastSample:samples.at(-1),realCameraOpened:true,microphoneOpened:false,recorded:false,
  trackingSamples:samples.length,reliableHipsSamples:samples.filter(s=>s.tracked?.hips).length,reliableTorsoSamples:samples.filter(s=>s.tracked?.torso).length,
  completeFaceSamples:samples.filter(s=>s.framing?.faceComplete).length,completeUpperSamples:samples.filter(s=>s.framing?.upperComplete).length,
  visibleHandSamples:samples.filter(s=>s.framing?.hands>0).length,standbySamples:samples.filter(s=>s.presence==='standby').length,
  allRotationsFinite:samples.every(s=>s.finite),maxRootXZDrift:Math.max(0,...samples.map(s=>s.rootXZDrift)),
  inferences:measured.inferences-baseline.inferences,renderedFrames:measured.renders-baseline.renders,
  latencySampleCount:latencies.length,latencyMedianMs:latencies[Math.floor(latencies.length*.5)],latencyP95Ms:latencies[Math.min(latencies.length-1,Math.floor(latencies.length*.95))],
  faceDetected:samples.some(s=>s.face>0),poseDetected:samples.some(s=>s.pose>0),handsDetected:samples.some(s=>s.hands>0),stopped,externalRequests:external,errors};
 await writeFile(out+'camera-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
 if(!report.passed)process.exitCode=1;
}catch(error){
 const state=await page?.evaluate(()=>{const v=document.getElementById('input');return {mode:window.avatarLab?.stats.mode,hidden:document.hidden,status:document.getElementById('status').textContent,videoReadyState:v.readyState,videoWidth:v.videoWidth,tracks:v.srcObject?.getTracks().map(t=>({kind:t.kind,readyState:t.readyState,muted:t.muted}))??[]};}).catch(()=>null);
 const failure={passed:false,error:error.message,state,recorded:false,externalRequests:external,errors};
 await writeFile(out+'camera-failure.json',JSON.stringify(failure,null,2));console.error(JSON.stringify(failure,null,2));process.exitCode=1;
}finally{clearTimeout(deadline);await browser?.close();await new Promise(resolve=>server.close(resolve));}
