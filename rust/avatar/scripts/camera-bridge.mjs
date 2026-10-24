// 本文件的目的：只在用户确认后启动原生视频发送器，使用匿名管道交付一帧最终 RGBA。
// 不保存图片；请求/管道均只有一个在途帧。会话令牌隔离多页、停止与迟到请求。
import {spawn} from 'node:child_process';
import {access} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {randomBytes} from 'node:crypto';
const BYTES=1280*720*4;
const built=fileURLToPath(new URL('../../build/camera/CallBridge Camera.app/Contents/MacOS/callbridge-camera-sender',import.meta.url));
const installed='/Applications/CallBridge Camera.app/Contents/MacOS/callbridge-camera-sender';
export class CameraBridge {
 constructor({memoryOnly=false,executable,target='callbridge'}={}){if(!['callbridge','obs'].includes(target))throw Error('未知摄像头目标');this.target=target;this.label=target==='obs'?'OBS Virtual Camera（本地测试）':'CallBridge Camera';this.memoryOnly=memoryOnly;this.executable=executable;this.epoch=0;this.owner=null;this.child=null;this.session=null;this.busy=false;this.waiter=null;this.error=null;}
 async path(){if(this.executable)return this.executable;if(this.target==='obs'){await access(built);return built;}try{await access(installed);return installed;}catch{await access(built);return built;}}
 async status(){return {...await this.deviceStatus(),label:this.label};}
 async deviceStatus(){
  if(this.child)return {installed:true,active:!!this.session,memoryOnly:this.memoryOnly};
  let path;try{path=await this.path();}catch{return {installed:false,active:false,error:'请先构建并安装 CallBridge Camera'};}
  if(this.memoryOnly)return {installed:true,active:false,memoryOnly:true};
  return new Promise(resolve=>{
   const child=spawn(path,[this.target==='obs'?'--obs-check':'--check'],{stdio:['ignore','pipe','ignore']});let text='';let done=false;
   const finish=value=>{if(done)return;done=true;clearTimeout(timer);resolve(value);};
   const timer=setTimeout(()=>{child.kill();finish({installed:false,active:false,error:'设备查询超时'});},3000);
   child.stdout.on('data',b=>{text+=b;if(text.length>8192)child.kill();});
   child.on('error',()=>finish({installed:false,active:false,error:'无法运行摄像头发送器'}));
   child.on('close',()=>{try{const result=JSON.parse(text.trim().split('\n')[0]);finish({...result,active:false});}catch{finish({installed:false,active:false,error:'摄像头查询失败'});}});
  });
 }
 async start(owner){
  if(this.owner)throw Error('已有视频发送会话，请先停止');
  if(!/^[a-f0-9-]{36}$/.test(owner))throw Error('会话标识无效');
  this.owner=owner;const epoch=++this.epoch;this.error=null;
  try{
   const executable=await this.path();if(epoch!==this.epoch)throw Error('启动已取消');
   const child=spawn(executable,this.memoryOnly?['--memory-check']:[this.target==='obs'?'--obs-send':'--send','--confirm-virtual-video'],{stdio:['pipe','pipe','pipe']});this.child=child;
   let buffer='';child.stderr.resume();
   child.stdout.on('data',chunk=>{
    if(epoch!==this.epoch)return;buffer+=chunk.toString();if(buffer.length>16384){this.fail('发送器响应过大',epoch);return;}
    let end;while((end=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,end);buffer=buffer.slice(end+1);try{const value=JSON.parse(line);if(this.waiter){const {resolve,timer}=this.waiter;this.waiter=null;clearTimeout(timer);resolve(value);}}catch{this.fail('发送器响应无效',epoch);}}
   });
   child.on('error',()=>this.fail('无法启动发送器',epoch));child.stdin.on('error',()=>this.fail('视频管道中断',epoch));
   child.on('exit',()=>this.fail('视频发送器已停止',epoch));
   const ready=await this.next(4000);if(epoch!==this.epoch)throw Error('启动已取消');
   if(!ready.ready)throw Error(ready.error??'设备未就绪');
   this.session=randomBytes(24).toString('hex');this.lastFrame=Date.now();
   this.watchdog=setInterval(()=>{if(Date.now()-this.lastFrame>1500)this.fail('画面已超时，输出停止',epoch);},250);
   return {session:this.session,memoryOnly:this.memoryOnly,label:this.label,width:1280,height:720};
  }catch(error){if(epoch===this.epoch)await this.stop(owner);throw error;}
 }
 next(ms){return new Promise((resolve,reject)=>{if(this.waiter)return reject(Error('已有在途响应'));const timer=setTimeout(()=>{this.waiter=null;reject(Error('发送器响应超时'));},ms);this.waiter={resolve,reject,timer};});}
 fail(message,epoch){if(epoch!==this.epoch)return;this.error=message;void this.stop(this.owner);}
 async stop(owner){
  if(owner!==this.owner)return false;++this.epoch;this.owner=null;this.session=null;this.busy=false;clearInterval(this.watchdog);
  if(this.waiter){clearTimeout(this.waiter.timer);this.waiter.reject(Error('输出已停止'));this.waiter=null;}
  const child=this.child;this.child=null;if(!child)return true;
  child.stdin.end();
  await new Promise(resolve=>{if(child.exitCode!==null||child.signalCode!==null)return resolve();const timer=setTimeout(()=>child.kill('SIGKILL'),1000);child.once('close',()=>{clearTimeout(timer);resolve();});});return true;
 }
 async frame(owner,session,data,sequence,ageNs){
  if(owner!==this.owner||!session||session!==this.session||!this.child)throw Error('输出会话已失效');
  if(this.busy)throw Error('视频帧正在发送');
  if(data.length!==BYTES||!Number.isSafeInteger(sequence)||sequence<=0||!Number.isSafeInteger(ageNs)||ageNs<0||ageNs>500000000)throw Error('视频帧格式或时间无效');
  this.busy=true;const epoch=this.epoch;
  try{
   const header=Buffer.alloc(24);header.write('CBV1');header.writeUInt32LE(BYTES,4);header.writeBigUInt64LE(BigInt(sequence),8);header.writeBigUInt64LE(BigInt(ageNs),16);
   const response=this.next(1500);this.child.stdin.write(header);this.child.stdin.write(data);
   const result=await response;if(epoch!==this.epoch)throw Error('输出已停止');
   if(result.sequence!==sequence)throw Error('发送器序号不匹配');if(result.error)throw Error(result.error);this.lastFrame=Date.now();return result;
  }catch(error){this.fail(error.message,epoch);throw error;}finally{if(epoch===this.epoch)this.busy=false;}
 }
}
