// 原生面板的私有管道桥：复用云端服务，不监听端口，不加载相机，也不输出凭据。
import {CloudService,CloudError} from './service.mjs';
import {pathToFileURL} from 'node:url';
export async function nativeCommand(service,request){
 if(!request||!Number.isSafeInteger(request.id)||request.id<1||typeof request.op!=='string')throw new CloudError('INVALID_REQUEST',400);
 if(Object.keys(request).some(k=>!['id','op','body','sessionId'].includes(k)))throw new CloudError('INVALID_REQUEST',400);
 switch(request.op){
 case 'catalog':return {providers:service.catalog()};
 case 'create':
  // 原生界面只有图片任务具备完整消费路径；禁止仅为预览创建会计费的实时房间。
  if(request.body?.provider!=='fashn')throw new CloudError('MEDIA_NOT_CONNECTED',409);
  {const result=await service.create(request.body,'http://127.0.0.1:1');const {connection,...snapshot}=result;void connection;return snapshot;}
 case 'poll':return service.poll(request.sessionId);
 case 'stop':return service.stop(request.sessionId);
 default:throw new CloudError('UNKNOWN_COMMAND',400);
 }
}
export function runNativeHost(input,output,service=new CloudService()){
 let pending=Buffer.alloc(0),busy=false,closing=false;
 const send=value=>output.write(JSON.stringify(value)+'\n');
 const finish=async()=>{if(closing)return;closing=true;await service.close();output.end();};
 input.on('data',chunk=>{
  pending=Buffer.concat([pending,chunk]);
  if(pending.length>512*1024){input.destroy();void finish();return;}
  for(let at;(at=pending.indexOf(10))!==-1;){
   const line=pending.subarray(0,at);pending=pending.subarray(at+1);
   let request;try{request=JSON.parse(line.toString());}catch{send({id:0,error:'INVALID_JSON'});continue;}
   if(busy||closing){send({id:request.id,error:'HOST_BUSY'});continue;}
   busy=true;
   void nativeCommand(service,request).then(result=>send({id:request.id,result}),error=>{
    // 远端错误体和请求素材不得进入原生日志。仅返回固定错误码及本地会话 ID。
    send({id:request.id,error:error instanceof CloudError?error.code:'INTERNAL_ERROR',...(error.sessionId?{sessionId:error.sessionId,result:service.snapshot(error.sessionId)}:{})});
   }).finally(()=>{busy=false;});
  }
 });
 input.on('end',()=>void finish());input.on('error',()=>void finish());
 return finish;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const finish=runNativeHost(process.stdin,process.stdout);
 for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>void finish());
}
