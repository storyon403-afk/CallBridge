// 本文件的目的：复用 KalidoKit 的解算，输出与渲染器无关的有界数值快照。
// 上游 Face.solve 会原地改写坐标，先复制；可见性决定哪些肢体信号能更新目标。
import * as Kalidokit from 'kalidokit/dist/kalidokit.es.js';
import {mouthShape,handBasis,framing,cameraPoint} from './signals.mjs';
export const bounded = (n, lo=-Math.PI, hi=Math.PI) => Number.isFinite(n) ? Math.min(hi,Math.max(lo,n)) : 0;
export function points(input, count) {
  return Array.isArray(input) && input.length === count && input.every(p=>p && ['x','y','z'].every(k=>Number.isFinite(p[k])))
    ? input.map(p=>({...p})) : null;
}
// 同时检查图像中的可见性和世界点置信度。退化的骨段不能提供可靠方向。
export function poseVisibility(pose,world){
  const visible=ids=>ids.every(i=>[pose[i],world[i]].every(p=>Number.isFinite(p.visibility)&&p.visibility>=.6)
    &&pose[i].x>=.01&&pose[i].x<=.99&&pose[i].y>=.01&&pose[i].y<=.99);
  const segment=(a,b)=>Math.hypot(...['x','y','z'].map(k=>world[a][k]-world[b][k]))>.025;
  const torso=visible([11,12])&&segment(11,12);
  const hips=torso&&visible([23,24])&&segment(23,24)&&segment(11,23)&&segment(12,24);
  const chain=ids=>visible(ids)&&segment(ids[0],ids[1])&&segment(ids[1],ids[2]);
  return {torso,hips,RightArm:torso&&chain([11,13,15]),LeftArm:torso&&chain([12,14,16]),
    RightLeg:hips&&chain([23,25,27]),LeftLeg:hips&&chain([24,26,28])};
}
export function solve(results, width, height) {
  if (!(width>0 && height>0 && width<=4096 && height<=4096)) throw Error('输入尺寸无效');
  const face=points(results.faceLandmarks,478) || points(results.faceLandmarks,468);
  const pose=points(results.poseLandmarks,33);
  // 固定 npm 0.5.1675471629 把 world_landmarks 导出名压缩为 za；不能照抄旧示例的 ea。
  const world=points(results.poseWorldLandmarks ?? results.za,33);
  const options={runtime:'mediapipe',imageSize:{width,height}};
  const shape=face?mouthShape(face,width,height):null;
  const output={face:null,pose:null,hands:{},handFrames:{},directions:{},fingerDirections:{}};
  if(pose && world){
    // KalidoKit 沿用自拍侧名（Right 对应输入索引 11/13/15），与手部交换一致。
    // 截断身体不能靠猜出的膝盖/脚踝带动腿；短缺失交给渲染层的有期限保持处理。
    output.visible=poseVisibility(pose,world);
    // 复用公开分部解算接口；Pose.solve 内按手腕高度/估计深度强制回默认姿势，
    // 会把真实下垂手臂误判为出画。失踪与恢复统一由本项目的置信度及时间处理。
    const arms=Kalidokit.Pose.calcArms(world),body=Kalidokit.Pose.calcHips(world,pose);
    output.pose={...body};
    for(const [side,key] of [['Left','l'],['Right','r']]){
      for(const bone of ['UpperArm','LowerArm','Hand'])output.pose[side+bone]=arms[bone][key];
      // 半身版只输出肩臂方向；世界点只取差值，不把相机中的人物位移传给角色。
      const ids=side==='Right'?[11,13,15]:[12,14,16];
      if(output.visible[side+'Arm'])for(const [bone,a,b] of [['UpperArm',ids[0],ids[1]],['LowerArm',ids[1],ids[2]]]){
        output.directions[side+bone]=cameraPoint(world[b],1,1).sub(cameraPoint(world[a],1,1)).normalize().toArray();
      }
    }
  }
  // 保持上游 sample/3d 的自拍侧命名；显示镜像不再二次交换输入。
  for (const [side,key] of [['Left','rightHandLandmarks'],['Right','leftHandLandmarks']]) {
    const hand=points(results[key],21);
    const basis=handBasis(hand,width,height);
    if (basis){
      output.handFrames[side]=basis.toArray();
      output.hands[side]=Kalidokit.Hand.solve(hand.map(p=>({...p,x:p.x*width,y:p.y*height,z:p.z*width})),side);
      // 每节手指的空间方向同时包含张开/并拢与弯曲；不能把指间展开全算成屈曲。
      for(const [finger,start] of [['Thumb',1],['Index',5],['Middle',9],['Ring',13],['Little',17]]){
        for(const [j,segment] of ['Proximal','Intermediate','Distal'].entries()){
          const direction=cameraPoint(hand[start+j+1],width,height).sub(cameraPoint(hand[start+j],width,height));
          if(direction.lengthSq()>.25)output.fingerDirections[side+finger+segment]=direction.normalize().toArray();
        }
      }
    }
  }
  // 必须在 Face.solve 原地放大坐标之前检查入画，并保存独立的口型结果。
  output.framing=framing(face,pose,output.visible,output.hands);
  if(output.framing.face){output.face=Kalidokit.Face.solve(face,{...options,blinkSettings:[.3,.5]});output.face.mouth.shape=shape;}
  return output;
}
// 代次隔离采集、异步模型初始化和迟到结果；始终至多一帧推理在途。
export class Gate {
  epoch=0; active=false; pending=false;
  start(){this.active=true;return ++this.epoch;}
  stop(){this.active=false;++this.epoch;}
  accepts(epoch){return this.active && this.epoch===epoch;}
  async frame(epoch,work,publish){
    if (!this.accepts(epoch)||this.pending) return false;
    this.pending=true;
    try {const result=await work();if(this.accepts(epoch)){publish(result);return true;}return false;}
    finally{this.pending=false;}
  }
}
