// 本文件的目的：把唯一最终画布送到本机原生发送器。原始视频与背景候选图没有传入此类。
// 无损 RGBA、固定 720p、最多一个 HTTP 请求在途；隐藏/停止/错误撤销本次会话，不自动重连。
export class VideoOutput {
 constructor(canvas,{status,start,stop,refresh}){
  this.canvas=canvas;this.label=status;this.startButton=start;this.stopButton=stop;this.refreshButton=refresh;
  this.active=false;this.starting=false;this.pending=false;this.epoch=0;this.sequence=0;this.last=0;this.token=null;this.owner=null;this.session=null;
  this.frame=document.createElement('canvas');this.frame.width=1280;this.frame.height=720;this.ctx=this.frame.getContext('2d',{willReadFrequently:true});
  stop.onclick=()=>this.stop();refresh.onclick=()=>this.refresh();this.controls(false);
 }
 controls(installed=this.installed){this.startButton.disabled=!installed||this.active||this.starting;this.stopButton.disabled=!this.active&&!this.starting;this.refreshButton.disabled=this.active||this.starting;}
 async refresh(){
  try{const response=await fetch('/camera/info',{cache:'no-store'});if(!response.ok)throw Error('摄像头状态不可用');const value=await response.json();this.token=value.token;this.installed=value.installed;this.memoryOnly=!!value.memoryOnly;this.targetLabel=value.label??'CallBridge Camera';
   this.label.textContent=value.installed?'未输出':value.error??'CallBridge Camera 尚未安装';
  }catch(error){this.installed=false;this.label.textContent=error.message;}this.controls();
 }
 headers(){return {'X-CB-Token':this.token,'X-CB-Owner':this.owner};}
 async start(){
  if(this.active||this.starting||!this.installed)return;
  const epoch=++this.epoch;this.owner=crypto.randomUUID();const headers=this.headers();this.starting=true;this.controls();this.label.textContent='连接中…';
  try{
   const response=await fetch('/camera/start',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({confirm:true})});const data=await response.json();
   if(epoch!==this.epoch){await fetch('/camera/stop',{method:'POST',headers,keepalive:true});return;}if(!response.ok||!data.session)throw Error(data.error??'视频输出启动失败');
   this.session=data.session;this.active=true;this.sequence=0;this.last=0;this.label.textContent=data.memoryOnly?'内存帧检查中 · 未发送到设备':'输出中';
  }catch(error){if(epoch===this.epoch)await this.stop('视频输出失败：'+error.message);}
  finally{if(epoch===this.epoch){this.starting=false;this.controls();}}
 }
 async stop(message='已停止'){
  const headers=this.headers(),hadOwner=!!this.owner;++this.epoch;this.active=false;this.starting=false;this.session=null;this.owner=null;
  this.label.textContent=message;this.controls();this.ctx.clearRect(0,0,1280,720);
  // 不等待旧帧 fetch 才发送停止：服务器会使其会话失效；第三方扩展不继承自有扩展的超时承诺。
  if(hadOwner){try{await fetch('/camera/stop',{method:'POST',headers,keepalive:true});}catch{this.label.textContent=message+' · 控制链路已断开，请在通话软件关闭摄像头';}}
 }
 async tick(now){
  if(!this.active||this.pending||now-this.last<1000/30)return;this.last=now;this.pending=true;
  const epoch=this.epoch,started=performance.now();
  try{
   // 各种面板比例都等比放入固定 16:9 输出，不拉伸人物；边缘用明确底色清空。
   const scale=Math.min(1280/this.canvas.width,720/this.canvas.height),w=this.canvas.width*scale,h=this.canvas.height*scale;
   this.ctx.fillStyle='#232b1f';this.ctx.fillRect(0,0,1280,720);this.ctx.drawImage(this.canvas,(1280-w)/2,(720-h)/2,w,h);
   const pixels=this.ctx.getImageData(0,0,1280,720).data;
   const response=await fetch('/camera/frame',{method:'POST',headers:{...this.headers(),'Content-Type':'application/octet-stream','X-CB-Session':this.session,'X-CB-Sequence':String(++this.sequence),'X-CB-Age-Ms':String(performance.now()-started)},body:pixels});
   const result=await response.json();if(epoch!==this.epoch)return;if(!response.ok)throw Error(result.error??'视频帧发送失败');
   this.lastResult=result;
  }catch(error){if(epoch===this.epoch)await this.stop('视频输出已停止：'+error.message);}
  finally{this.pending=false;}
 }
}
