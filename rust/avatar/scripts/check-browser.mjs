// 本文件的目的：在独立浏览器上下文真实跑模型/渲染；主动设备接口被替身拦截。
// 不使用摄像头授权绕过参数，不读取常用浏览器资料，不播放/录音/发送虚拟设备。
import {chromium} from 'playwright-core';import assert from 'node:assert/strict';
import {mkdir,writeFile} from 'node:fs/promises';import {fileURLToPath} from 'node:url';
import path from 'node:path';import {startServer} from './server.mjs';
const out=fileURLToPath(new URL('../../build/avatar-check/',import.meta.url));await mkdir(out,{recursive:true});
const server=await startServer(0),origin=`http://127.0.0.1:${server.address().port}`;
let browser;const errors=[],external=[];
// 防止测试本身出现等待缺陷时留下浏览器和本地服务。
const deadline=setTimeout(()=>browser?.close(),120000);deadline.unref();
try{
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const context=await browser.newContext({viewport:{width:1000,height:900},deviceScaleFactor:1,permissions:[]});
 // 本脚本继续覆盖静态空背景采集；实时人物背景组合由 check-live-avatar.mjs 独立验证。
 await context.addInitScript(()=>{window.callbridgeComposition={person:'avatar',background:'plate'};});
 await context.route('**/*',route=>{const url=route.request().url();if(url.startsWith(origin+'/'))return route.continue();external.push(url);return route.abort();});
 await context.addInitScript(()=>{
  window.mediaCalls=[];navigator.mediaDevices.getUserMedia=constraints=>{window.mediaCalls.push(constraints);return new Promise(resolve=>window.releaseFakeCamera=()=>resolve({getTracks:()=>[{stop:()=>window.fakeStopped=true}]}));};
 });
 const page=await context.newPage();page.on('pageerror',e=>{errors.push(e.message);console.error(e.message);});
 page.on('console',m=>{if(m.type()==='error'){errors.push(m.text());console.error('browser:',m.text());}});
 await page.goto(origin);await page.waitForFunction(()=>window.avatarLab?.stats.ready,{},{timeout:60000});
 assert.equal(await page.evaluate(()=>mediaCalls.length),0);
 // 同一真实 GPU 帧检查 alpha：透明角色画布不得混入测试图或摄像头像素。
 const initial=await page.evaluate(()=>{
  const a=avatarLab;a.renderer.render(a.scene,a.camera);const gl=a.renderer.getContext();const p=new Uint8Array(gl.drawingBufferWidth*gl.drawingBufferHeight*4);
  gl.readPixels(0,0,gl.drawingBufferWidth,gl.drawingBufferHeight,gl.RGBA,gl.UNSIGNED_BYTE,p);
  let opaque=0,transparent=0,teal=0;for(let i=3;i<p.length;i+=4){if(p[i]>0){opaque++;if(p[i-2]>p[i-3]*1.1&&p[i-1]>p[i-3]*1.1)teal++;}else transparent++;}
  return {opaque,transparent,teal,head:a.vrm.humanoid.getNormalizedBoneNode('neck').quaternion.toArray(),arm:a.vrm.humanoid.getNormalizedBoneNode('leftUpperArm').quaternion.toArray(),renderer:gl.getParameter(gl.RENDERER)};
 });
 assert.ok(initial.opaque>1000&&initial.transparent>1000,JSON.stringify(initial));
 assert.ok(initial.teal>8000,'实际像素必须显示青色服装，而不只是材质字段被设置');
 await page.screenshot({path:path.join(out,'preview.png')});
 await page.click('#demo');await page.waitForTimeout(600);
 const moving=await page.evaluate(()=>avatarLab.vrm.humanoid.getNormalizedBoneNode('neck').quaternion.toArray());assert.notDeepEqual(moving,initial.head);
 await page.click('#stop');assert.equal(await page.evaluate(()=>avatarLab.vrm.expressionManager.getValue('aa')),0);
 assert.equal(await page.locator('#view').count(),0);
 assert.equal(await page.evaluate(()=>avatarLab.stats.appearance.addedMeshes),14);
 const result=await page.evaluate(()=>avatarLab.fixture());
 assert.equal(result.pose,33,JSON.stringify(result));assert.equal(result.face,478,JSON.stringify(result));assert.equal(result.fixtureSettled,true);assert.ok(result.fixtureFrames>=2&&result.fixtureFrames<=8);
 const segmentation=await page.evaluate(()=>avatarLab.replacement.fraction);
 assert.ok(segmentation>.01&&segmentation<.9,`真实 Holistic 遮罩占比异常：${segmentation}`);
 const changed=await page.evaluate(()=>avatarLab.vrm.humanoid.getNormalizedBoneNode('leftUpperArm').quaternion.toArray());assert.notDeepEqual(changed,initial.arm);assert.ok(changed.every(Number.isFinite));
 // 用可控在途任务制造快速切换；真实 WASM 可能连续占用主线程，不能靠轮询抓瞬间状态。
 const restarted=await page.evaluate(async()=>{
  avatarLab.stop();const epoch=avatarLab.gate.start();let release,stale=0;
  const first=avatarLab.gate.frame(epoch,()=>new Promise(r=>release=r),()=>stale++);
  const before=avatarLab.stats.inferences;
  setTimeout(()=>release(null),25);
  await avatarLab.fixture();await first;
  return {added:avatarLab.stats.inferences-before,frames:avatarLab.stats.fixtureFrames,settled:avatarLab.stats.fixtureSettled,mode:avatarLab.stats.mode,stale};
 });
 assert.equal(restarted.added,restarted.frames);assert.ok(restarted.frames>=2&&restarted.frames<=8);assert.equal(restarted.settled,true);assert.equal(restarted.mode,'fixture');assert.equal(restarted.stale,0);
 // 平滑渲染在推理结束后继续收敛；不能拿更新目标瞬间的骨架误作最终效果。
 await page.waitForTimeout(500);
 const settled=await page.evaluate(()=>{
  const m=avatarLab.motion;
  return {finite:[...m.bones.values()].every(b=>b.node.quaternion.toArray().every(Number.isFinite)),
   armError:m.bones.get('LeftUpperArm').node.getWorldQuaternion(m.bones.get('LeftUpperArm').target.clone()).angleTo(m.bones.get('LeftUpperArm').target),
   tracked:avatarLab.stats.tracked,root:m.hips.position.toArray(),restRoot:m.restPosition.toArray()};
 });
 assert.equal(settled.finite,true);assert.ok(settled.armError<.02);
 assert.equal(settled.tracked.hips,true);assert.equal(settled.tracked.LeftArm,true);assert.equal(settled.tracked.RightArm,true);
 assert.equal(settled.root[0],settled.restRoot[0]);assert.equal(settled.root[2],settled.restRoot[2]);
 await page.screenshot({path:path.join(out,'tracking.png')});
 const portrait=await page.evaluate(()=>{
  const a=avatarLab,m=a.motion,v=a.vrm;const rest=m.restPosition.toArray();
  const legKeys=['leftUpperLeg','leftLowerLeg','rightUpperLeg','rightLowerLeg'];
  const fixedLegs=legKeys.every(k=>v.humanoid.getNormalizedBoneNode(k).quaternion.angleTo(m.bones.get(k[0].toUpperCase()+k.slice(1)).rest)<1e-7);
  const armErrors=[];
  for(const side of ['Left','Right'])for(const [bone,child] of [['UpperArm','LowerArm'],['LowerArm','Hand']]){
   const b=m.bones.get(side+bone),c=m.bones.get(side+child),bind=m.armBindings.get(side+bone);
   const actual=c.node.getWorldPosition(c.node.position.clone()).sub(b.node.getWorldPosition(b.node.position.clone())).normalize();
   const expected=bind.direction.clone().applyQuaternion(bind.rotation.clone().invert()).applyQuaternion(b.target);
   armErrors.push(actual.angleTo(expected));
  }
  return {fixedLegs,root:a.motion.hips.position.toArray(),rest,framing:a.stats.framing,armErrors,appearance:a.stats.appearance};
 });
 assert.equal(portrait.fixedLegs,true);assert.deepEqual(portrait.root,portrait.rest);
 assert.ok(portrait.armErrors.every(e=>e<.02));assert.equal(portrait.framing.upperComplete,true);
 // 检查真正的模型变形绑定，而非只确认表达式名称存在。
 const mouth=await page.evaluate(()=>{
  const a=avatarLab; a.stop();const output={};
  for(const [key,name,targetName] of [['A','aa','A'],['I','ih','I'],['E','ee','E'],['O','oh','O'],['U','ou','U']]){
   const shape={A:0,I:0,E:0,O:0,U:0};shape[key]=.9;
   a.apply({framing:{person:true,faceComplete:true,upperComplete:true,hands:0},face:{head:{x:0,y:0,z:0},eye:{l:1,r:1},pupil:{x:0,y:0},mouth:{shape}}});
   a.motion.tick(.5,performance.now(),true);a.vrm.update(.01);
   let weight=0;a.vrm.scene.traverse(n=>{const index=n.morphTargetDictionary?.['Face_Blendshape.Fcl_MTH_'+targetName];if(index!==undefined)weight=Math.max(weight,n.morphTargetInfluences[index]);});
   output[name]=weight;
  }
  return output;
 });
 assert.ok(Object.values(mouth).every(v=>v>.85));
 // 将构造的 21 点张掌/握拳送过同一个解算入口，再检查真实角色指骨变化。
 const handStates=[];
 for(const closed of [false,true]){
  const result=await page.evaluate(closed=>{
   const a=avatarLab;a.stop();const hand=Array.from({length:21},()=>({x:.5,y:.8,z:0}));
   for(const [start,x,y] of [[5,.42,.55],[9,.5,.52],[13,.57,.55],[17,.64,.6]]){
    hand[start]={x,y,z:0};
    for(let j=1;j<4;j++)hand[start+j]=closed?{x,y:y+[-.03,.035,.08][j-1],z:[-.07,-.09,-.04][j-1]}:{x,y:y-.075*j,z:0};
   }
   for(let i=1;i<5;i++)hand[i]={x:.48-.045*i,y:.8-.04*i,z:0};
   const rig=a.solve({rightHandLandmarks:hand},640,480);
   rig.framing={person:true,faceComplete:true,upperComplete:true,hands:1};
   rig.pose={LeftUpperArm:{x:0,y:0,z:.4},LeftLowerArm:{x:0,y:0,z:-1.5}};
   a.apply(rig);for(let i=0;i<80;i++)a.motion.tick(1/60,performance.now(),true);a.vrm.update(.01);
   const b=a.motion.bones.get('LeftHand'),q=b.node.getWorldQuaternion(b.target.clone());
   const joint=a.vrm.humanoid.getNormalizedBoneNode('leftMiddleIntermediate'),tip=a.vrm.humanoid.getNormalizedBoneNode('leftMiddleDistal');
   const direction=tip.getWorldPosition(tip.position.clone()).sub(joint.getWorldPosition(joint.position.clone())).normalize();
   const expected=direction.clone().fromArray(rig.fingerDirections.LeftMiddleIntermediate);
   return {finger:joint.quaternion.toArray(),fingerDirectionError:direction.angleTo(expected),palmError:q.angleTo(b.target),binds:a.motion.handBindings.size};
  },closed);
  handStates.push(result);await page.screenshot({path:path.join(out,closed?'hand-closed.png':'hand-open.png')});
 }
 assert.notDeepEqual(handStates[0].finger,handStates[1].finger);
 assert.ok(handStates.every(s=>s.binds===2&&s.palmError<.02));
 assert.ok(handStates.every(s=>s.fingerDirectionError<.02));

 await page.click('#demo');await page.waitForTimeout(500);await page.screenshot({path:path.join(out,'gesture.png')});
 // 摄像头开着时无人待机与主动停止分开；此处只注入数值和空结果，不用真实设备。
 const idle=await page.evaluate(()=>{
  const a=avatarLab;a.stop();a.presence.update({person:true},performance.now()-2000);a.apply(a.solve({},640,480));
  a.motion.tick(.5,performance.now(),false,true);return {idle:a.presence.state(performance.now()).idle,mouth:a.vrm.expressionManager.getValue('aa'),root:a.motion.hips.position.toArray()};
 });
 assert.equal(idle.idle,true);assert.equal(idle.mouth,0);assert.deepEqual(idle.root,portrait.rest);

 // 用已知像素验证真正的最终画布：真人红块须消失、背景左右一致、角色可见；不只检查状态字段。
 const replacement=await page.evaluate(()=>{
  const create=(w,h,color)=>{const c=document.createElement('canvas');c.width=w;c.height=h;if(color){const x=c.getContext('2d');x.fillStyle=color;x.fillRect(0,0,w,h);}return c;};
  const out=create(80,60),candidate=create(1,1),plate=create(80,60,'#e0c080'),avatar=create(80,60);
  const r=new avatarLab.replacement.constructor(out,candidate),pix=(x,y)=>Array.from(out.getContext('2d').getImageData(x,y,1,1).data);
  r.begin(0);for(const t of [4000,4250,4500,4750,5000])r.accept(plate,null,{},t);
  r.draw(avatar,5000);const before=pix(40,30),review=r.capture.state;
  const confirmed=r.confirm();r.draw(avatar,5000);const clean=pix(40,30);
  const frame=create(80,60,'#2040e0'),ctx=frame.getContext('2d');ctx.fillStyle='#ff0000';ctx.fillRect(28,10,24,50);ctx.fillStyle='#00ff00';ctx.fillRect(0,0,5,5);
  const mask=create(80,60),mc=mask.getContext('2d');mc.fillStyle='#fff';mc.fillRect(28,10,24,50);
  const landmarks={faceLandmarks:Array.from({length:478},()=>({x:.5,y:.3,z:0})),poseLandmarks:Array.from({length:33},()=>({x:.5,y:.7,z:0,visibility:1}))};
  r.accept(frame,mask,landmarks,5100);r.draw(avatar,5100);const center=pix(40,30),edge=pix(10,30),mirrored=pix(78,2),live=r.state(5100).live;
  let red=0;const pixels=out.getContext('2d').getImageData(0,0,80,60).data;for(let i=0;i<pixels.length;i+=4)if(pixels[i]>240&&pixels[i+1]<20&&pixels[i+2]<20)red++;
  // 修改源帧不能影响已经发布的同帧合成；旧帧到期后只剩干净背景。
  ctx.fillStyle='#ff0000';ctx.fillRect(0,0,80,60);r.draw(avatar,5200);const frozen=pix(10,30);
  r.draw(avatar,5351);const stale=pix(10,30),expired=r.state(5351).live;
  r.accept(frame,null,landmarks,5400);r.draw(avatar,5400);const missing=pix(40,30);
  const full=create(80,60,'#fff');r.accept(frame,full,landmarks,5500);r.draw(avatar,5500);const fullMask=pix(40,30);
  const empty=create(80,60);r.accept(frame,empty,landmarks,5600);r.draw(avatar,5600);const emptyMask=pix(40,30);
  const broken={...landmarks,faceLandmarks:landmarks.faceLandmarks.map(p=>({...p,x:NaN}))};r.accept(frame,mask,broken,5600);r.draw(avatar,5600);const invalidLandmarks=pix(40,30);
  const ac=avatar.getContext('2d');ac.fillStyle='#8030d0';ac.fillRect(38,28,4,4);r.draw(avatar,5600);const overlay=pix(40,30);
  r.reset();r.draw(avatar,5700);const stopped={ready:r.hasPlate,plate:r.plate.width,candidate:r.candidate.width,pixel:pix(10,30)};
  // 快速重新采集不会复用已确认背景；输入尺寸改变也必须作废背景。
  r.begin(6000);for(const t of [10000,10250,10500,10750,11000])r.accept(plate,null,{},t);r.confirm();r.accept(create(40,30),null,{},11100);
  return {review,confirmed,before,clean,center,edge,mirrored,live,red,frozen,stale,expired,missing,fullMask,emptyMask,invalidLandmarks,overlay,stopped,sizeInvalidated:!r.hasPlate};
 });
 assert.equal(replacement.review,'review');assert.equal(replacement.confirmed,true);assert.notDeepEqual(replacement.before,replacement.clean);
 assert.deepEqual(replacement.clean,[224,192,128,255]);assert.deepEqual(replacement.center,replacement.clean);assert.equal(replacement.red,0);
 assert.deepEqual(replacement.edge,[32,64,224,255]);assert.deepEqual(replacement.mirrored,[0,255,0,255]);assert.equal(replacement.live,true);
 assert.deepEqual(replacement.frozen,replacement.edge);assert.deepEqual(replacement.stale,replacement.clean);assert.equal(replacement.expired,false);
 for(const key of ['missing','fullMask','emptyMask','invalidLandmarks'])assert.deepEqual(replacement[key],replacement.clean);
 assert.deepEqual(replacement.overlay,[128,48,208,255]);assert.equal(replacement.stopped.ready,false);assert.equal(replacement.stopped.plate,1);assert.equal(replacement.stopped.candidate,1);assert.equal(replacement.sizeInvalidated,true);

 assert.equal(await page.evaluate(()=>mediaCalls.length),0);
 // 授权等待中的停止：后到的 MediaStream 只释放，不允许激活跟踪。
 await page.click('#camera');await page.waitForFunction(()=>mediaCalls.length===1);
 const constraints=await page.evaluate(()=>mediaCalls[0]);assert.equal(constraints.audio,false);
 await page.click('#stop');await page.evaluate(()=>releaseFakeCamera());await page.waitForFunction(()=>fakeStopped===true);
 assert.equal(await page.evaluate(()=>avatarLab.stats.camera),false);
 assert.match(await page.locator('#tracking').innerText(),/待机/);
 // 将合成空房间和公开照片作为浏览器内视频流，走完整按钮/相机/推理/确认链；不访问物理设备。
 await page.evaluate(async()=>{
  const image=new Image();image.src='fixtures/pose.jpg';await image.decode();
  const c=document.createElement('canvas');c.width=image.width;c.height=image.height;const ctx=c.getContext('2d');
  window.replacementVideo={person:false,running:true};
  const draw=()=>{ctx.fillStyle='#c4d6e4';ctx.fillRect(0,0,c.width,c.height);ctx.fillStyle='#9fb6c8';ctx.fillRect(0,c.height*.8,c.width,c.height*.2);
   if(replacementVideo.person)ctx.drawImage(image,0,0);if(replacementVideo.running)requestAnimationFrame(draw);};draw();
  navigator.mediaDevices.getUserMedia=async constraints=>{mediaCalls.push(constraints);const stream=c.captureStream(30);window.replacementTracks=stream.getTracks();return stream;};
 });
 await page.click('#camera');await page.waitForFunction(()=>avatarLab.stats.camera);
 await page.click('#capture-background');
 await page.waitForFunction(()=>avatarLab.replacement.capture.state==='review',{},{timeout:20000});
 await page.locator('#background-review').waitFor({state:'visible'});
 assert.equal(await page.locator('#background-review').isVisible(),true);
 assert.equal(await page.evaluate(()=>avatarLab.replacement.hasPlate),false);
 await page.click('#confirm-background');await page.waitForFunction(()=>avatarLab.replacement.hasPlate);
 await page.evaluate(()=>replacementVideo.person=true);
 await page.waitForFunction(()=>avatarLab.replacement.state(performance.now()).live,{},{timeout:20000});
 const videoReplacement=await page.evaluate(()=>({camera:avatarLab.stats.camera,face:avatarLab.stats.face,pose:avatarLab.stats.pose,
  replacement:avatarLab.replacement.state(performance.now()),source:{width:document.getElementById('input').videoWidth,height:document.getElementById('input').videoHeight},
  output:{width:document.getElementById('output').width,height:document.getElementById('output').height}}));
 assert.equal(videoReplacement.face,478);assert.equal(videoReplacement.pose,33);
 await page.screenshot({path:path.join(out,'replacement.png')});
 await page.evaluate(()=>replacementVideo.person=false);
 await page.waitForFunction(()=>avatarLab.stats.presence==='standby'&&!avatarLab.replacement.state(performance.now()).live,{},{timeout:15000});
 assert.equal(await page.evaluate(()=>avatarLab.replacement.hasPlate),true);
 await page.evaluate(()=>replacementVideo.person=true);
 await page.waitForFunction(()=>avatarLab.stats.presence==='tracking'&&avatarLab.replacement.state(performance.now()).live,{},{timeout:15000});
 videoReplacement.leaveAndReturn=true;
 await page.click('#capture-background');await page.click('#stop');
 const replacementStopped=await page.evaluate(()=>{replacementVideo.running=false;return {tracks:replacementTracks.map(t=>t.readyState),phase:avatarLab.replacement.capture.state,
  plate:avatarLab.replacement.plate.width,candidate:avatarLab.replacement.candidate.width,sourceCleared:document.getElementById('input').srcObject===null};});
 assert.ok(replacementStopped.tracks.every(s=>s==='ended'));assert.equal(replacementStopped.phase,'empty');assert.equal(replacementStopped.plate,1);assert.equal(replacementStopped.candidate,1);assert.equal(replacementStopped.sourceCleared,true);
 await page.setViewportSize({width:375,height:760});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 await page.screenshot({path:path.join(out,'narrow.png')});
 assert.equal((await fetch(origin+'/src/../../../../AGENTS.md')).status,404);
 assert.equal((await fetch(origin,{method:'POST'})).status,405);
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
 const report={passed:true,browserVersion:browser.version(),renderer:initial.renderer,opaquePixels:initial.opaque,tealClothingPixels:initial.teal,transparentPixels:initial.transparent,
   tracking:result,segmentation,replacement,videoReplacement,replacementStopped,restarted,settled,portrait,mouth,handStates,idle,stoppedPendingCamera:true,syntheticMediaRequests:2,realCameraOpened:false,microphoneOpened:false,externalRequests:external,errors};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}catch(error){
 await writeFile(path.join(out,'report.json'),JSON.stringify({passed:false,error:error.message,realCameraOpened:false,microphoneOpened:false,externalRequests:external,errors},null,2));throw error;
}finally{clearTimeout(deadline);await browser?.close();await new Promise(resolve=>server.close(resolve));}
