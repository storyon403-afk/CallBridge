// 私有宿主 API 使用现有 Origin/Host 防护与会话令牌；不允许 CORS 或任意代理路径。
import {CloudError} from './service.mjs';
export async function cloudRoute({req,res,pathname,origin,token,service,json,body}){
 if(!pathname.startsWith('/cloud/v1/'))return false;
 try{
  if(pathname==='/cloud/v1/info'&&req.method==='GET'){json(res,200,{schema:1,token,mediaConnected:false});return true;}
  if(req.headers['x-cb-token']!==token)throw new CloudError('LOCAL_AUTH_REQUIRED',403);
  if(pathname==='/cloud/v1/providers'&&req.method==='GET'){json(res,200,{providers:service.catalog()});return true;}
  if(req.method==='POST'&&req.headers.origin!==origin)throw new CloudError('ORIGIN_REQUIRED',403);
  if(pathname==='/cloud/v1/sessions'&&req.method==='POST'){
   if(req.headers['content-type']!=='application/json')throw new CloudError('JSON_REQUIRED',415);
   let data;try{data=JSON.parse((await body(req,512*1024)).toString());}catch{throw new CloudError('INVALID_JSON',400);}
   json(res,201,await service.create(data,origin));return true;
  }
  const match=/^\/cloud\/v1\/sessions\/([a-f0-9-]{36})(?:\/(stop|poll))?$/.exec(pathname);
  if(match){
   if(req.method==='GET'&&!match[2])json(res,200,service.snapshot(match[1]));
   else if(req.method==='POST'&&match[2]==='stop')json(res,200,await service.stop(match[1]));
   else if(req.method==='POST'&&match[2]==='poll')json(res,200,await service.poll(match[1]));
   else throw new CloudError('METHOD_NOT_ALLOWED',405);
   return true;
  }
  throw new CloudError('ROUTE_NOT_FOUND',404);
 }catch(error){
  const known=error instanceof CloudError;
  json(res,known?error.status:500,{error:known?error.code:'INTERNAL_ERROR',...(known&&error.sessionId?{sessionId:error.sessionId}:{})});return true;
 }
}
