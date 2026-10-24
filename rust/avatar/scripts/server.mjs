// 本文件的目的：提供本地资源和经会话授权的最终视频帧管道；无外网上传、代理或任意目录浏览。
import http from 'node:http';
import {readFile,realpath,open} from 'node:fs/promises';
import {constants} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {randomBytes} from 'node:crypto';
import {CameraBridge} from './camera-bridge.mjs';
const root=process.env.CB_AVATAR_ASSETS??fileURLToPath(new URL('../../build/avatar/',import.meta.url));
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript','.css':'text/css','.wasm':'application/wasm','.json':'application/json','.jpg':'image/jpeg','.txt':'text/plain; charset=utf-8','.mp4':'video/mp4','.mov':'video/quicktime','.webm':'video/webm'};
export async function startServer(port=5778,{camera=new CameraBridge(),backgroundFile=process.env.CB_BACKGROUND_FILE??null}={}){
 const base=await realpath(root);
 const plugin=process.env.CB_AVATAR_PLUGIN?await realpath(process.env.CB_AVATAR_PLUGIN):null;
 const token=randomBytes(32).toString('hex');let receiving=false,statusPromise=null;
 const json=(res,status,value)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(JSON.stringify(value));};
 const body=(req,limit)=>new Promise((resolve,reject)=>{
  const parts=[];let total=0;const timeout=setTimeout(()=>{req.destroy();reject(Error('帧接收超时'));},800);
  req.on('data',b=>{total+=b.length;if(total>limit){clearTimeout(timeout);req.destroy();reject(Error('请求过大'));}else parts.push(b);});
  req.on('end',()=>{clearTimeout(timeout);resolve(Buffer.concat(parts));});req.on('error',error=>{clearTimeout(timeout);reject(error);});
 });
 // WebKit 会以字节范围探测 MP4；内建和导入素材必须走同一有界读取路径。
 const media=async(filename,req,res)=>{
    const file=await open(filename,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
    let handedOff=false;
    try{
     const info=await file.stat();if(!info.isFile()||info.size<1||info.size>64*1024*1024)throw Error('background size');
     let start=0,end=info.size-1;const range=req.headers.range;
     if(range){const match=/^bytes=(\d+)-(\d*)$/.exec(range);if(!match){res.writeHead(416);return res.end();}
      start=Number(match[1]);end=match[2]?Number(match[2]):end;
      if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=info.size){res.writeHead(416);return res.end();}end=Math.min(end,info.size-1);}
     const headers={'Content-Type':types[path.extname(filename).toLowerCase()],'Content-Length':end-start+1,'Accept-Ranges':'bytes','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Cross-Origin-Resource-Policy':'same-origin'};
     if(range)headers['Content-Range']=`bytes ${start}-${end}/${info.size}`;
     res.writeHead(range?206:200,headers);if(req.method==='HEAD')return res.end();
     const stream=file.createReadStream({start,end,autoClose:true});handedOff=true;
     stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());stream.pipe(res);return;
    }finally{if(!handedOff)await file.close();}
 };
 const server=http.createServer(async(req,res)=>{
  try{
   if(req.headers.host!==`127.0.0.1:${server.address().port}`){res.writeHead(403);return res.end();}
   const url=new URL(req.url,'http://127.0.0.1');const rel=decodeURIComponent(url.pathname);
   if(rel==='/background/custom'&&['GET','HEAD'].includes(req.method)){
    if(req.headers['sec-fetch-site']==='cross-site'||(req.headers.origin&&req.headers.origin!==`http://${req.headers.host}`)){res.writeHead(403);return res.end();}
    // 只读取宿主文件选择器传入的一份素材；HTTP 不接受路径，也不能列出私人目录。
    if(!backgroundFile||!['.mp4','.mov','.webm'].includes(path.extname(backgroundFile).toLowerCase()))throw Error('background');
    return await media(backgroundFile,req,res);
   }
   if(rel==='/camera/info'&&req.method==='GET'){
    statusPromise??=camera.status().finally(()=>{statusPromise=null;});const state=await statusPromise;
    return json(res,200,{...state,token});
   }
   if(rel.startsWith('/camera/')&&req.method==='POST'){
    if(req.headers.origin!==`http://${req.headers.host}`||req.headers['x-cb-token']!==token)return json(res,403,{error:'本地视频授权无效'});
    const owner=req.headers['x-cb-owner'];
    if(rel==='/camera/start'){
     const request=JSON.parse((await body(req,1024)).toString());if(request.confirm!==true)return json(res,403,{error:'需要主动确认视频发送'});
     try{return json(res,200,await camera.start(owner??''));}catch(error){return json(res,409,{error:error.message});}
    }
    if(rel==='/camera/stop')return json(res,200,{stopped:await camera.stop(owner)});
    if(rel==='/camera/frame'){
     if(receiving)return json(res,429,{error:'帧接收繁忙'});
     if(owner!==camera.owner||!camera.session||req.headers['x-cb-session']!==camera.session)return json(res,409,{error:'视频会话无效'});
     if(req.headers['content-type']!=='application/octet-stream'||Number(req.headers['content-length'])!==1280*720*4)return json(res,400,{error:'视频帧尺寸无效'});
     receiving=true;const started=performance.now();
     try{
      const data=await body(req,1280*720*4),sequence=Number(req.headers['x-cb-sequence']),age=Number(req.headers['x-cb-age-ms']);
      if(!Number.isFinite(age)||age<0||age>500)return json(res,400,{error:'帧时间无效'});
      const result=await camera.frame(owner,req.headers['x-cb-session'],data,sequence,Math.round((age+performance.now()-started)*1e6));return json(res,200,result);
     }catch(error){return json(res,409,{error:error.message});}finally{receiving=false;}
    }
    return json(res,404,{error:'未知视频接口'});
   }
   if(!['GET','HEAD'].includes(req.method)){res.writeHead(405);return res.end();}
   if(rel.includes('\0')||rel.includes('\\'))throw Error('path');
   // 大型模型/跟踪资源只从通过原生安装校验的插件目录读取，页面与宿主脚本仍来自签名 App。
   const source=plugin&&(rel.startsWith('/vendor/holistic/')||rel.startsWith('/model/'))?plugin:base;
   const file=await realpath(path.join(source,rel==='/'?'index.html':rel));
   if(!file.startsWith(source+path.sep))throw Error('outside');
   if(['.mp4','.mov','.webm'].includes(path.extname(file)))return await media(file,req,res);
   const data=await readFile(file);
   res.writeHead(200,{'Content-Type':types[path.extname(file)]??'application/octet-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer',
    'Permissions-Policy':'camera=(self), microphone=(), geolocation=()',
    // GLTFLoader 通过 fetch 读取模型内嵌纹理的 blob；只放行本机内存 URL，不开放远端源。
    'Content-Security-Policy':"default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self' blob:; worker-src 'self' blob:; object-src 'none'; frame-ancestors 'none'"});
   res.end(req.method==='HEAD'?undefined:data);
  }catch{res.writeHead(404);res.end('Not found');}
 });
 server.on('close',()=>{void camera.stop(camera.owner);});server.requestTimeout=5000;
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});
 return server;
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
 const port=Number(process.env.CB_AVATAR_PORT??5778);if(!Number.isInteger(port)||port<0||port>65535)throw Error('端口无效');
 const target=process.env.CB_AVATAR_CAMERA??'callbridge';
 // 原生宿主通过私有 stdin 管道持有服务；宿主退出/崩溃的 EOF 也必须关闭发送器。
 // 内存检查只能由本机启动参数指定，HTTP 客户端无法将真实输出偷偷改成测试通过。
 const hosted=process.argv.includes('--app-host');
 const camera=new CameraBridge({target,executable:hosted?process.env.CB_AVATAR_SENDER:undefined,memoryOnly:hosted&&process.argv.includes('--memory-check')});
 const server=await startServer(port,{camera});
 console.log(hosted?JSON.stringify({port:server.address().port}):`CallBridge 形象实验：http://127.0.0.1:${server.address().port}\n采集与视频输出默认关闭；当前输出目标：${target}；需主动启用。按 Ctrl+C 退出。`);
 let closing=false;
 const shutdown=async()=>{if(closing)return;closing=true;server.close();server.closeAllConnections();await camera.stop(camera.owner);process.exit();};
 for(const signal of ['SIGINT','SIGTERM'])process.on(signal,shutdown);
 if(hosted){process.stdin.resume();process.stdin.on('end',shutdown);}
}
