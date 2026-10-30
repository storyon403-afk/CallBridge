// 本文件的目的：复用正式角色、服装及骨骼驱动，展示可交互的预设动作；不包含采集、推理或设备输出。
import * as THREE from 'three';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';
import {VRMLoaderPlugin,VRMUtils} from '@pixiv/three-vrm';
import {dressAvatar} from '../../rust/avatar/src/appearance.mjs';
import {AvatarMotion} from '../../rust/avatar/src/motion.mjs';
import {drawParallax} from '../../rust/avatar/src/background.mjs';
export async function createViewer(canvas,signal){
 const response=await fetch(new URL('./cheng.vrm',import.meta.url),{signal});
 if(!response.ok)throw Error('Model unavailable');
 const bytes=await response.arrayBuffer();
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),v=>v.toString(16).padStart(2,'0')).join('');
 if(digest!=='12c2b97e95e700783a6a550dc0eee2d7880aeedccef9ae67bc4c5a2f0f2631a2')throw Error('Model checksum mismatch');
 const loader=new GLTFLoader();loader.register(parser=>new VRMLoaderPlugin(parser));
 const gltf=await loader.parseAsync(bytes,'');const vrm=gltf.userData.vrm;
 if(signal.aborted){VRMUtils.deepDispose(vrm.scene);throw new DOMException('Aborted','AbortError');}
 let renderer;
 try{renderer=new THREE.WebGLRenderer({alpha:true,antialias:true});}catch(e){VRMUtils.deepDispose(vrm.scene);throw e;}
 renderer.setSize(960,600);renderer.setPixelRatio(1);
 canvas.width=960;canvas.height=600;const ctx=canvas.getContext('2d');
 const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(35,1.6,.1,20);
 camera.position.set(0,1.30,1.30);camera.lookAt(0,1.30,0);
 scene.add(new THREE.HemisphereLight(0xffffff,0x657c72,2));const light=new THREE.DirectionalLight(0xffffff,2);light.position.set(1,2,3);scene.add(light);
 VRMUtils.rotateVRM0(vrm);scene.add(vrm.scene);dressAvatar(vrm);const motion=new AvatarMotion(vrm);
 let background='window',action='idle',playing=true,visible=true,disposed=false,last=0,time=0,raf=0;
 const reduce=matchMedia('(prefers-reduced-motion: reduce)');playing=!reduce.matches;
 function paint(now){
  const dt=last?Math.min((now-last)/1000,.05):0;last=now;
  if(playing)time+=dt*1000;
  const t=time,blink=t%4200>4000?0:1,turn=action==='turn'?.45: .10;
  const hand={LeftWrist:{x:0,y:.18*Math.sin(t/450),z:0}};
  for(const f of ['Index','Middle','Ring','Little'])for(const s of ['Proximal','Intermediate','Distal'])hand['Left'+f+s]={x:0,y:0,z:.15};
  motion.accept({face:{head:{x:.035*Math.sin(t/900),y:turn*Math.sin(t/1000),z:.025*Math.cos(t/1100)},eye:{l:blink,r:blink},pupil:{x:0,y:0},mouth:{shape:{A:0,I:0,E:0,O:0,U:0}}},pose:{Spine:{x:0,y:.04*Math.sin(t/1600),z:0},...(action==='wave'?{LeftUpperArm:{x:0,y:0,z:.5},LeftLowerArm:{x:0,y:0,z:-1.5+.12*Math.sin(t/180)}}:{})},hands:action==='wave'?{Left:hand}:{}},t);
  motion.tick(playing?dt:0,t,false,false);vrm.update(playing?dt:0);
  if(background==='window')drawParallax(ctx,960,600,t,.2*Math.sin(t/1000));
  else{const g=ctx.createLinearGradient(0,0,960,600);g.addColorStop(0,background==='mint'?'#b9cec5':'#24252b');g.addColorStop(1,background==='mint'?'#698c86':'#0c1014');ctx.fillStyle=g;ctx.fillRect(0,0,960,600);}
  renderer.render(scene,camera);ctx.drawImage(renderer.domElement,0,0);canvas.dataset.ready='true';
 }
 function loop(now){if(disposed)return;if(visible&&!document.hidden)paint(now);else last=0;raf=requestAnimationFrame(loop);}
 const observer=new IntersectionObserver(entries=>{visible=entries[0].isIntersecting;},{threshold:.01});observer.observe(canvas);
 paint(performance.now());raf=requestAnimationFrame(loop);
 return {setBackground(value){background=value;},setAction(value){action=value;motion.reset();},setPlaying(value){playing=value;},dispose(){disposed=true;cancelAnimationFrame(raf);observer.disconnect();VRMUtils.deepDispose(vrm.scene);renderer.dispose();renderer.forceContextLoss();}};
}
