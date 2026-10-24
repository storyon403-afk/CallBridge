// 本文件的目的：经明确授权，用合成角色验证 OBS 真正的虚拟设备及 WebRTC 本机接收。
// 只按精确名称/设备 ID 打开 OBS；不请求物理相机或音频，不使用 STUN/TURN，不拨号或录制。
import assert from 'node:assert/strict';
import {writeFile,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright-core';
import {CameraBridge} from './camera-bridge.mjs';
import {startServer} from './server.mjs';
if(process.argv[2]!=='--confirm-virtual-video')throw Error('需要明确授权虚拟视频读写：--confirm-virtual-video');
const out=fileURLToPath(new URL('../../build/camera/',import.meta.url));await mkdir(out,{recursive:true});
const camera=new CameraBridge({target:'obs'});assert.equal((await camera.status()).installed,true,'OBS 虚拟摄像头尚未就绪');
const server=await startServer(0,{camera}),origin=`http://127.0.0.1:${server.address().port}`;
let browser,page;const errors=[],external=[],observations={};
const deadline=setTimeout(()=>browser?.close(),90000);deadline.unref();
try{
 browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const context=await browser.newContext({viewport:{width:1280,height:1000},permissions:[]});
 // 用户授权本次虚拟设备测试；这里只配置浏览器站点许可，系统 TCC 仍由 macOS 决定。
 await context.grantPermissions(['camera'],{origin});
 await context.route('**/*',route=>{if(route.request().url().startsWith(origin+'/'))return route.continue();external.push(route.request().url());return route.abort();});
 page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin);await page.waitForFunction(()=>window.avatarLab?.stats.ready&&avatarLab.videoOutput.installed);
 await page.click('#demo');await page.click('#send-video');
 await page.waitForFunction(()=>avatarLab.videoOutput.lastResult?.queued===true);
 const capture=await page.evaluate(async()=>{
  const list=await navigator.mediaDevices.enumerateDevices();
  const target=list.find(d=>d.kind==='videoinput'&&d.label==='OBS Virtual Camera');
  if(!target?.deviceId)throw Error('未找到唯一的 OBS Virtual Camera，拒绝回退默认摄像头');
  const stream=await navigator.mediaDevices.getUserMedia({audio:false,video:{deviceId:{exact:target.deviceId}}});
  window.obsTest={stream};
  if(stream.getAudioTracks().length)throw Error('测试不应存在音频轨道');
  const pc1=new RTCPeerConnection({iceServers:[]}),pc2=new RTCPeerConnection({iceServers:[]});
  Object.assign(obsTest,{pc1,pc2});
  const to1=[],to2=[];
  const ice=(peer,queue,candidate)=>{if(!candidate)return;if(!peer.remoteDescription){queue.push(candidate);return;}peer.addIceCandidate(candidate).catch(error=>obsTest.error=String(error));};
  pc1.onicecandidate=e=>ice(pc2,to2,e.candidate);pc2.onicecandidate=e=>ice(pc1,to1,e.candidate);
  const receiver=document.createElement('video');receiver.id='obs-receiver';receiver.autoplay=true;receiver.muted=true;receiver.playsInline=true;receiver.style.width='480px';
  document.body.append(receiver);obsTest.receiver=receiver;
  pc2.ontrack=e=>{receiver.srcObject=e.streams[0];void receiver.play();};
  for(const track of stream.getVideoTracks())pc1.addTrack(track,stream);
  await pc1.setLocalDescription(await pc1.createOffer());await pc2.setRemoteDescription(pc1.localDescription);
  for(const candidate of to2)await pc2.addIceCandidate(candidate);
  await pc2.setLocalDescription(await pc2.createAnswer());await pc1.setRemoteDescription(pc2.localDescription);
  for(const candidate of to1)await pc1.addIceCandidate(candidate);
  return {label:stream.getVideoTracks()[0].label,settings:stream.getVideoTracks()[0].getSettings(),audioTracks:stream.getAudioTracks().length};
 });
 await page.waitForFunction(()=>obsTest.receiver.videoWidth>0&&obsTest.pc2.connectionState==='connected');
 await page.waitForFunction(async()=>{for(const r of (await obsTest.pc2.getStats()).values())if(r.type==='inbound-rtp'&&r.kind==='video'&&r.framesDecoded>=30)return true;return false;},{},{timeout:20000});
 const sample=()=>page.evaluate(()=>{
  const video=obsTest.receiver,c=document.createElement('canvas');c.width=320;c.height=180;
  const ctx=c.getContext('2d');ctx.drawImage(video,0,0,320,180);const rgba=ctx.getImageData(0,0,320,180).data;
  // 服装为青绿，OBS 停止占位图为深蓝；绿/蓝比例排除占位图，不能只看红色低。
  let teal=0;for(let i=0;i<rgba.length;i+=4)if(rgba[i]<100&&rgba[i+1]>rgba[i]*1.3&&rgba[i+2]>rgba[i]*1.2&&rgba[i+1]>rgba[i+2]*0.8&&rgba[i+1]<180)teal++;
  return {teal,pixels:Array.from(rgba),time:video.currentTime,width:video.videoWidth,height:video.videoHeight};
 });
 await page.waitForTimeout(1500);const first=await sample();await page.waitForTimeout(1600);const second=await sample();
 assert.ok(first.teal>500&&second.teal>500,'接收画面没有检测到角色服装，可能仍是占位图');
 let changed=0;for(let i=0;i<first.pixels.length;i+=4)if(Math.abs(first.pixels[i]-second.pixels[i])+Math.abs(first.pixels[i+1]-second.pixels[i+1])>35)changed++;
 assert.ok(changed>100,'角色接收画面没有运动变化');
 const rtc=await page.evaluate(async()=>{
  const stats=await obsTest.pc2.getStats();let result={};for(const r of stats.values())if(r.type==='inbound-rtp'&&r.kind==='video'&&Number.isFinite(r.framesDecoded)&&r.framesDecoded>(result.framesDecoded??-1))result={framesDecoded:r.framesDecoded,framesReceived:r.framesReceived,frameWidth:r.frameWidth,frameHeight:r.frameHeight,framesPerSecond:r.framesPerSecond,codecId:r.codecId};
  return {inbound:result,error:obsTest.error??null,producerSequence:avatarLab.videoOutput.sequence,physicalCamera:avatarLab.stats.camera};
 });
 // 前面已等待解码 30 帧；此处记录采样时刻的接收统计，不把重复采样作为帧率验收。
 assert.ok(rtc.inbound.framesDecoded>0,JSON.stringify(rtc));assert.equal(rtc.error,null);assert.equal(rtc.physicalCamera,false);
 await page.locator('#obs-receiver').screenshot({path:out+'obs-webrtc-received.png'});
 await page.click('#stop-video');await page.waitForTimeout(3000);const stopped=await sample();
 Object.assign(observations,{capture,rtc,changedPixels:changed,teal:[first.teal,second.teal,stopped.teal]});
 await page.locator('#obs-receiver').screenshot({path:out+'obs-webrtc-stopped.png'});
 assert.ok(stopped.teal<100,'停止后仍在接收角色画面');assert.equal(camera.child,null);
 const ended=await page.evaluate(()=>{obsTest.stream.getTracks().forEach(t=>t.stop());obsTest.pc1.close();obsTest.pc2.close();return obsTest.stream.getTracks().map(t=>t.readyState);});
 assert.deepEqual(ended,['ended']);assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
 const report={passed:true,capture,rtc,changedPixels:changed,teal:[first.teal,second.teal,stopped.teal],ended,external,errors,physicalCameraOpened:false,microphoneOpened:false,virtualDeviceStarted:true,wechatRemoteVerified:false};
 await writeFile(out+'obs-device-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}catch(error){const state=await page?.evaluate(()=>({status:document.querySelector('#video-status')?.textContent,active:window.avatarLab?.videoOutput.active,last:window.avatarLab?.videoOutput.lastResult})).catch(()=>null);await writeFile(out+'obs-device-report.json',JSON.stringify({passed:false,error:String(error),state,observations,bridgeError:camera.error,external,errors},null,2));throw error;}
finally{clearTimeout(deadline);await browser?.close();await camera.stop(camera.owner);await new Promise(r=>server.close(r));}
