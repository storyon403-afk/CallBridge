// 本文件的目的：迁移 Kalidoface 的 MediaPipe → KalidoKit → VRM 路径，独立于音频。
// 数值快照驱动角色；最终画面由独立人物/背景槽合成，只有两槽都不替换时显示相机原帧。
import * as THREE from 'three';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';
import {VRMLoaderPlugin, VRMUtils} from '@pixiv/three-vrm';
import {solve,Gate} from './rig.mjs';
import {AvatarMotion} from './motion.mjs';
import {Presence} from './signals.mjs';
import {dressAvatar} from './appearance.mjs';
import {ReplacementCompositor} from './replacement.mjs';
import {VideoOutput} from './video-output.mjs';
import {composition,BackgroundSource} from './background.mjs';
const $=id=>document.getElementById(id), gate=new Gate(),presence=new Presence();
const effects=composition(window.callbridgeComposition),backgroundSource=new BackgroundSource(effects.background);
const directCamera=effects.person==='none'&&effects.background==='original';
let headOffset=0,lastCameraFrame=-Infinity;
const composite=now=>{
 replacement.draw(renderer.domElement,now,{...effects,source:backgroundSource,head:headOffset});
 // 正常现场画面独立于人物推理，避免模型延迟让视频变成间歇更新的静帧。
 if(directCamera&&stats.camera&&video.readyState>=2&&now>=lastCameraFrame&&now-lastCameraFrame<=250)replacement.drawOriginal(video);
};
const stats={ready:false,mode:'idle',renders:0,inferences:0,face:0,pose:0,hands:0,latencyMs:[],camera:false,microphone:false};
let vrm, motion, tracker, trackerPromise, stream, demo=false, lastVideoTime=-1;
let expectedEpoch=0, trackerEpoch=0, trackerResult=null, frameTime=performance.now(), lastRender=0;
const video=$('input'), renderer=new THREE.WebGLRenderer({canvas:$('avatar'),alpha:true,antialias:true});
const replacement=new ReplacementCompositor($('output'),$('background-candidate'),{realtime:effects.person==='avatar'&&effects.background==='original'});
const videoOutput=new VideoOutput($('output'),{status:$('video-status'),start:$('send-video'),stop:$('stop-video'),refresh:$('refresh-video')});
// 推理在途时冻结这一帧；遮罩必须对应同一张图，不能套在已经推进的 HTMLVideoElement 上。
const inferenceFrame=document.createElement('canvas'),compositeFrame=document.createElement('canvas'),resultMask=document.createElement('canvas');
let capturedAt=0;
function replacementUI(now){
 const needsPlate=effects.background==='plate';
 const s=replacement.state(now);stats.replacement=s;$('replacement-status').textContent=s.message;$('replacement-status').hidden=!needsPlate||!stats.camera||(s.phase==='idle'&&replacement.hasPlate);
 $('capture-background').hidden=!needsPlate;
 $('capture-background').disabled=!stats.camera||s.phase==='countdown';
 $('background-review').hidden=s.phase!=='review';
}
renderer.setPixelRatio(Math.min(devicePixelRatio,2));
const scene=new THREE.Scene(), camera=new THREE.PerspectiveCamera(35,16/9,.1,20);
// 半身通话构图固定中心与高度，不再恢复旧版全身视角或跟随猜测的髋部位移。
function framePortrait(){
 camera.position.set(0,1.30,1.30);camera.lookAt(0,1.30,0);
 // 窄屏适度退后，至少留出肩与近身手势的宽度；构图仍从腰部以上开始。
 camera.position.z=Math.max(1.30,.70/(2*Math.tan(THREE.MathUtils.degToRad(camera.fov/2))*camera.aspect));
 camera.updateProjectionMatrix();
}
framePortrait();
scene.add(new THREE.HemisphereLight(0xffffff,0x657c72,2));
const light=new THREE.DirectionalLight(0xffffff,2);light.position.set(1,2,3);scene.add(light);
function neutral(){motion?.reset();}
function apply(rig){
 headOffset=rig.face?.head?.y??0;
 const now=performance.now();
 if(rig.framing)presence.update(rig.framing,now);
 stats.presence=presence.state(now).idle?'standby':'tracking';
 motion?.accept(rig.framing?.person===false?{}:rig,now);
}
function trackingStatus(now){
 if(directCamera&&stats.camera){$('tracking').hidden=true;$('mode').textContent='实时画面';return false;}
 const state=presence.state(now,stats.mode==='fixture');stats.presence=state.idle?'standby':'tracking';
 const f=state.framing;
 const text=stats.mode==='demo'?'演示中 · 非真人捕捉':!stats.camera&&stats.mode!=='fixture'?'待机 · 等待开启摄像头':
  state.idle?'未检测到人物 · 待机':!f?.faceComplete?'面部未完整入画 · 请正对镜头':
  !f?.upperComplete?'面部已捕捉 · 请让肩部和肘部入画':`半身已入画 · 手部 ${f.hands}/2`;
 $('tracking').hidden=!stats.camera;
 if($('tracking').textContent!==text)$('tracking').textContent=text;
 $('tracking').dataset.state=state.idle?'idle':f?.upperComplete?'ready':'partial';
 if(stats.camera)$('mode').textContent=state.idle?'待机 · 摄像头开启':'半身跟踪';
 return state.idle;
}
// 视频发送状态只由独立输出控件显示，避免跟踪提示仍写“未发送”而实际已经启用。
function setStatus(message){const needed=/失败|未开启|丢失|超时|不可用/.test(message);$('status').textContent=needed?message:'';$('status').hidden=!needed;}
function stop(){
 backgroundSource.pause();headOffset=0;lastCameraFrame=-Infinity;
 void videoOutput.stop();
 gate.stop();demo=false;stream?.getTracks().forEach(t=>t.stop());stream=null;video.pause();video.srcObject=null;
 stats.camera=false;stats.tracked=null;stats.framing=null;presence.reset();stats.mode='idle';lastVideoTime=-1;neutral();$('mode').textContent='本地预览';$('camera').disabled=!stats.ready;
 replacement.reset();replacementUI(performance.now());renderer.render(scene,camera);composite(performance.now());
 setStatus('已停止 · 摄像头关闭 · 麦克风关闭 · 视频未发送');
}
async function ensureTracker(){
 if(tracker)return tracker;if(trackerPromise)return trackerPromise;
 trackerPromise=(async()=>{
  await new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='vendor/holistic/holistic.js';s.onload=resolve;s.onerror=()=>reject(Error('跟踪资源缺失，请重新构建'));document.head.append(s);});
  const h=new window.Holistic({locateFile:file=>new URL('vendor/holistic/'+file,location.href).href});
  h.setOptions({modelComplexity:1,smoothLandmarks:true,refineFaceLandmarks:true,enableSegmentation:true,smoothSegmentation:true,selfieMode:false,minDetectionConfidence:.7,minTrackingConfidence:.7});
  h.onResults(results=>{
   if(!gate.accepts(expectedEpoch))return;
   // MediaPipe 图像属于回调借用资源，必须在回调返回前复制；下一次推理可以复用其 GPU 缓冲。
   const mask=results.segmentationMask;
   if(mask){resultMask.width=compositeFrame.width;resultMask.height=compositeFrame.height;resultMask.getContext('2d').drawImage(mask,0,0,resultMask.width,resultMask.height);}
   trackerResult={...results,image:undefined,segmentationMask:mask?resultMask:null};
  });
  await h.initialize();tracker=h;return h;
 })().catch(error=>{trackerPromise=null;throw error;});return trackerPromise;
}
async function infer(image,epoch){
 let ownsFrame=false;
 return gate.frame(epoch,async()=>{
  ownsFrame=true;
  const h=await ensureTracker();if(!gate.accepts(epoch))return null;
  // 相机与固定图切换会改变裁切/ROI。只在单帧闸门内重置图状态，保留已加载权重。
  // 否则上一来源的追踪框可能令新来源连续漏脸/漏手，三张测试图也未必能恢复。
  if(trackerEpoch!==epoch){await h.reset();trackerEpoch=epoch;if(!gate.accepts(epoch))return null;}
  const width=image.videoWidth||image.naturalWidth||image.width,height=image.videoHeight||image.naturalHeight||image.height;
  if(!(width>0&&height>0&&width<=4096&&height<=4096))throw Error('相机帧尺寸无效');
  // 跟踪保持原输入分辨率；仅背景合成副本限为 640×480，不能为瘦身降低面部输入细节。
  inferenceFrame.width=width;inferenceFrame.height=height;inferenceFrame.getContext('2d').drawImage(image,0,0,width,height);
  const scale=Math.min(1,640/width,480/height);compositeFrame.width=Math.max(1,Math.round(width*scale));compositeFrame.height=Math.max(1,Math.round(height*scale));
  compositeFrame.getContext('2d').drawImage(inferenceFrame,0,0,compositeFrame.width,compositeFrame.height);
  expectedEpoch=epoch;trackerResult=null;const t=performance.now();capturedAt=t;await h.send({image:inferenceFrame});
  const result=trackerResult;trackerResult=null; // 及时释放模型返回的相机图像引用，不进入历史数组。
  if(!result)return null;
  const value=solve(result,inferenceFrame.width,inferenceFrame.height);return {value,result,latency:performance.now()-t,face:result.faceLandmarks?.length||0,pose:result.poseLandmarks?.length||0,hands:(result.leftHandLandmarks?.length||0)+(result.rightHandLandmarks?.length||0)};
 },result=>{if(!result)return;
  replacement.accept(compositeFrame,result.result.segmentationMask,result.result,performance.now(),capturedAt);
  apply(result.value);stats.tracked=result.value.visible??null;stats.framing=result.value.framing;stats.inferences++;stats.face=result.face;stats.pose=result.pose;stats.hands=result.hands;stats.latencyMs.push(result.latency);if(stats.latencyMs.length>120)stats.latencyMs.shift();
 }).finally(()=>{if(ownsFrame){for(const c of [inferenceFrame,compositeFrame,resultMask]){c.width=1;c.height=1;}trackerResult=null;}});
}
async function fixture(){
 stop();const epoch=gate.start();stats.mode='fixture';$('mode').textContent='测试图驱动';setStatus('公开测试图 → 跟踪 → 角色，不开启摄像头');
 // 快速从采集切到测试时，先让旧推理自然结束；等待可被停止代次打断，不排队新帧。
 while(gate.pending && gate.accepts(epoch))await new Promise(resolve=>setTimeout(resolve,16));
 if(!gate.accepts(epoch))return {...stats};
 const image=new Image();image.src='fixtures/pose.jpg';await image.decode();
 if(!gate.accepts(epoch))return {...stats};
 // 侧脸/小手的 ROI 可能需要多于三次调用才稳定。最多八次，不无限重试；
 // 连续两次都得到脸/身体/双手才称为完整测试，失败也保留真实点数。
 stats.fixtureFrames=0;stats.fixtureSettled=false;stats.face=0;stats.pose=0;stats.hands=0;let stable=0;
 for(let i=0;i<8 && gate.accepts(epoch);i++){
  const before=stats.inferences;await infer(image,epoch);
  if(!gate.accepts(epoch))return {...stats};
  stats.fixtureFrames++;
  stable=stats.inferences>before&&stats.face>=468&&stats.pose===33&&stats.hands===42?stable+1:0;
  if(stable>=2){stats.fixtureSettled=true;break;}
 }
 if(gate.accepts(epoch))setStatus(`${stats.fixtureSettled?'测试完成':'测试图未完整识别，可重试'} · 面部 ${stats.face} 点 / 身体 ${stats.pose} 点 / 手部 ${stats.hands} 点 · 视频未发送`);
 return {...stats};
}
async function startCamera(){
 stop();const epoch=gate.start();stats.mode='starting';$('camera').disabled=true;setStatus('准备跟踪资源…摄像头尚未开启');
 try{
  if(!directCamera)await ensureTracker();if(!gate.accepts(epoch))return;
  setStatus('等待摄像头授权或设备启动… · 麦克风关闭');
  // 只在按钮点击后请求视频；不请求 microphone，浏览器权限不绕过。
  const acquired=await navigator.mediaDevices.getUserMedia({video:{width:{ideal:640},height:{ideal:480},frameRate:{ideal:30,max:30}},audio:false});
  if(!gate.accepts(epoch)){acquired.getTracks().forEach(t=>t.stop());return;}
  stream=acquired;video.srcObject=acquired;setStatus('摄像头已连接，等待视频帧… · 麦克风关闭');await video.play();
  if(!gate.accepts(epoch))return;
 stats.camera=true;stats.mode='camera';$('mode').textContent='摄像头跟踪';setStatus(effects.background==='plate'?'摄像头已开启 · 请采集空背景':'摄像头已开启');
  await backgroundSource.play();
  for(const track of stream.getVideoTracks())track.addEventListener('ended',()=>{if(gate.accepts(epoch))stop();});
 }catch(error){if(gate.accepts(epoch)){stop();setStatus('摄像头未开启：'+error.message);}}
}
function demoStart(){stop();demo=true;stats.mode='demo';$('mode').textContent='动作演示';void backgroundSource.play().catch(e=>setStatus('背景播放失败：'+e.message));setStatus('合成动作演示 · 未使用摄像头 · 视频未发送');}
function animate(now){
 requestAnimationFrame(animate);
 // 保留超出的帧间余量，避免 60 Hz 下用 now 重置后实际掉成 20 fps。
 const interval=1000/60,elapsed=now-lastRender;if(elapsed<interval)return;lastRender=now-elapsed%interval;
 const dt=Math.min((now-frameTime)/1000,.1);frameTime=now;
 if(demo){
  const shape={A:0,I:0,E:0,O:0,U:0};shape[['A','I','E','O','U'][Math.floor(now/1400)%5]]=.35+.5*Math.abs(Math.sin(now/350));
  const hand={LeftWrist:{x:0,y:.3*Math.sin(now/800),z:0}};
  for(const finger of ['Index','Middle','Ring','Little'])for(const segment of ['Proximal','Intermediate','Distal'])hand['Left'+finger+segment]={x:0,y:0,z:.65+.6*Math.sin(now/700)};
  apply({face:{head:{x:.1*Math.sin(now/600),y:.3*Math.sin(now/1000),z:.08*Math.cos(now/900)},eye:{l:1,r:1},pupil:{x:0,y:0},mouth:{shape}},
   pose:{Spine:{x:0,y:.1*Math.sin(now/1300),z:0},LeftUpperArm:{x:0,y:0,z:.5},LeftLowerArm:{x:0,y:0,z:-1.5}},hands:{Left:hand}});
 }
 const idle=trackingStatus(now);motion?.tick(dt,now,stats.mode==='fixture',idle&&!demo);
 if(stats.mode==='camera' && video.readyState>=2 && video.currentTime!==lastVideoTime && !gate.pending){
  lastVideoTime=video.currentTime;
  if(directCamera)lastCameraFrame=now;
  else {const epoch=gate.epoch;infer(video,epoch).catch(error=>{if(gate.accepts(epoch)){stop();setStatus('跟踪已停止：'+error.message);}});}
 }
 vrm?.update(dt);renderer.render(scene,camera);composite(now);replacementUI(now);stats.renders++;
 void videoOutput.tick(now);stats.videoOutput={active:videoOutput.active,starting:videoOutput.starting,sequence:videoOutput.sequence};
 if(stats.renders%30===0)$('stats').textContent=JSON.stringify({...stats,latencyMs:undefined,inferenceLastMs:stats.latencyMs.at(-1)?.toFixed(1)},null,2);
}
function resize(){const r=$('stage').getBoundingClientRect();renderer.setSize(r.width,r.height,false);camera.aspect=r.width/r.height;framePortrait();
 const scale=Math.min(1,1280/r.width,720/r.height);$('output').width=Math.max(1,Math.round(r.width*scale));$('output').height=Math.max(1,Math.round(r.height*scale));}
// 紧凑窗口中预览可能暂时位于滚动区域外；按钮初始状态不能等待首个绘制帧。
replacementUI(performance.now());
new ResizeObserver(resize).observe($('stage'));resize();requestAnimationFrame(animate);
$('stop').onclick=stop;$('demo').onclick=demoStart;$('camera').onclick=startCamera;
$('send-video').onclick=()=>{
 if(!stats.ready)return;
 if(effects.background==='plate'&&!replacement.hasPlate){$('video-status').textContent='请先采集并确认空背景，再输出到通话';return;}
 if(effects.person==='none'&&effects.background==='original'&&!stats.camera){$('video-status').textContent='请先开启摄像头';return;}
 const epoch=gate.epoch;
 void backgroundSource.play().then(()=>{if(epoch===gate.epoch&&!document.hidden)return videoOutput.start();}).catch(e=>{if(epoch===gate.epoch)setStatus('背景播放失败：'+e.message);});
};
$('capture-background').onclick=()=>{if(stats.camera){void videoOutput.stop();replacement.begin(performance.now());setStatus('请离开镜头至少五秒，保持机位不动 · 视频未发送');}};
$('confirm-background').onclick=()=>{if(replacement.confirm())setStatus('背景已确认，可以返回镜头 · 本地替换预览 · 视频未发送');};
$('cancel-background').onclick=()=>{replacement.reset();setStatus('已放弃背景，可重新采集 · 摄像头仍开启 · 视频未发送');};
$('fixture').onclick=()=>fixture().catch(error=>{stop();setStatus('测试失败：'+error.message);});
addEventListener('pagehide',stop);document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();});
$('avatar').addEventListener('webglcontextlost',event=>{event.preventDefault();stop();setStatus('渲染上下文丢失，请重新打开原型');});
async function load(){
 await backgroundSource.prepare();stats.composition=effects;
 // 不替换人物时不下载/解析 VRM；跟踪权重只在主动采集或测试时加载。
 if(effects.person==='none'){
  stats.ready=true;for(const id of ['camera','fixture'])$(id).disabled=false;
  $('demo').textContent='预览背景';$('demo').disabled=false;void videoOutput.refresh();return;
 }
 const manifest=await (await fetch('assets.json')).json();const asset=manifest.files.find(f=>f.name==='sample.vrm');
 const buffer=await (await fetch('model/sample.vrm')).arrayBuffer();
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',buffer)),x=>x.toString(16).padStart(2,'0')).join('');
 if(hash!==asset.sha256||buffer.byteLength!==asset.bytes)throw Error('示例角色校验失败');
 const loader=new GLTFLoader();loader.register(parser=>new VRMLoaderPlugin(parser));
 const gltf=await loader.parseAsync(buffer,'');vrm=gltf.userData.vrm;if(!vrm)throw Error('未识别 VRM 角色');
 VRMUtils.rotateVRM0(vrm);scene.add(vrm.scene);stats.appearance=dressAvatar(vrm);motion=new AvatarMotion(vrm);neutral();stats.ready=true;
 $('hint').textContent='澄 · 半身通话形象';
 for(const id of ['demo','camera','fixture'])$(id).disabled=false;
 setStatus('角色已就绪 · 摄像头关闭 · 麦克风关闭 · 视频未发送');
 void videoOutput.refresh();
}
// 仅测试构建暴露数值状态与演示入口，不提供录音、上传或默认设备访问。
window.avatarLab={stats,fixture,stop,demo:demoStart,apply,gate,renderer,scene,camera,presence,solve,replacement,videoOutput,effects,backgroundSource,get motion(){return motion;},get vrm(){return vrm;}};
load().catch(error=>{setStatus('加载失败：'+error.message);$('hint').textContent='加载失败，请检查构建资源';});
