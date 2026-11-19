// 组合台只渲染一帧中性姿势，不启动跟踪器、摄像头或输出设备。
import * as THREE from 'three';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';
import {VRMLoaderPlugin, VRMUtils} from '@pixiv/three-vrm';
import {AvatarMotion} from './motion.mjs';

let renderer;
window.renderStudioPortrait = async function(bytes) {
  const manager=new THREE.LoadingManager();
  manager.setURLModifier(url=>{
    if (/^(blob:|data:)/.test(url)) return url;
    throw Error('Expected an embedded VRM texture');
  });
  const loader=new GLTFLoader(manager);
  loader.register(parser=>new VRMLoaderPlugin(parser));
  const gltf=await loader.parseAsync(bytes,'');
  const vrm=gltf.userData.vrm;
  try {
    VRMUtils.rotateVRM0(vrm);
    new AvatarMotion(vrm).reset();
    vrm.update(0);
    const scene=new THREE.Scene();
    scene.add(vrm.scene,new THREE.HemisphereLight(0xffffff,0x657c72,2));
    const light=new THREE.DirectionalLight(0xffffff,2);
    light.position.set(1,2,3);
    scene.add(light);
    const camera=new THREE.PerspectiveCamera(35,1,.1,20);
    camera.position.set(0,1.3,1.3);
    camera.lookAt(0,1.3,0);
    renderer??=new THREE.WebGLRenderer({alpha:true,antialias:true});
    renderer.setSize(480,480,false);
    renderer.setClearColor(0,0);
    renderer.render(scene,camera);
    return await new Promise((resolve,reject)=>renderer.domElement.toBlob(blob=>blob?resolve(URL.createObjectURL(blob)):reject(Error('No portrait'))));
  } finally { VRMUtils.deepDispose(gltf.scene); }
};
