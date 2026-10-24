// 本文件的目的：在旋转空间实现 1€ 的速度自适应低通，抑制静止噪声而保留快速动作。
// 根据 https://gery.casiez.net/1euro/ 的公式独立实现；不是逐个 Euler 分量平均。
// 时间输入为毫秒，角速度为 rad/s；四元数的 q/-q 和跨 ±π 采用同一最短弧。
import {Quaternion,Vector3} from 'three';
const alpha=(dt,hz)=>1/(1+1/(2*Math.PI*hz*dt));
export class RotationFilter{
 constructor(){this.reset();}
 reset(){this.raw=null;this.value=null;this.time=null;this.velocity=new Vector3();this.pending=null;}
 sample(q,time){
  if(!Number.isFinite(time)||!q.toArray().every(Number.isFinite))return null;
  if(this.time!==null&&time<=this.time)return null;
  if(this.time===null||time-this.time>250){
   this.raw=q.clone();this.value=q.clone();this.time=time;this.velocity.set(0,0,0);this.pending=null;return this.value;
  }
  const dt=(time-this.time)/1000,angle=this.raw.angleTo(q);
  // 单帧突然翻身先等待下一帧证实；连续快速动作最多多等一帧，不永久锁死。
  if(angle>1&&angle/dt>12){
   const confirmed=this.pending&&time-this.pending.time<=150&&this.pending.q.angleTo(q)<.25;
   if(!confirmed){this.pending={q:q.clone(),time};return null;}
  }
  this.pending=null;
  const delta=this.raw.clone().invert().multiply(q).normalize();
  if(delta.w<0)delta.set(-delta.x,-delta.y,-delta.z,-delta.w);
  const sin=Math.hypot(delta.x,delta.y,delta.z),radians=2*Math.atan2(sin,delta.w);
  const speed=new Vector3(delta.x,delta.y,delta.z).multiplyScalar(sin>1e-8?radians/(sin*dt):0);
  this.velocity.lerp(speed,alpha(dt,1));
  this.value.slerp(q,alpha(dt,1.5+.6*this.velocity.length()));
  this.raw.copy(q);this.time=time;return this.value;
 }
}
