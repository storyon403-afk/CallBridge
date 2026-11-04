// 云端控制服务运行于非实时 Node 线程；不打开麦克风/摄像头，不写虚拟设备。
// 长期凭据仅从宿主注入读取；请求端点由代码固定，禁止把它变为任意 URL 代理。
import {randomUUID} from 'node:crypto';
import {PROVIDERS,providerById} from './providers.mjs';
export class CloudError extends Error {
 constructor(code,status=400){super(code);this.code=code;this.status=status;}
}
const fail=(code,status)=>{throw new CloudError(code,status);};
function object(value){if(!value||typeof value!=='object'||Array.isArray(value))fail('INVALID_REQUEST');return value;}
function exact(value,keys){object(value);if(Object.keys(value).some(k=>!keys.includes(k)))fail('UNKNOWN_FIELD');}
function id(value){if(typeof value!=='string'||!/^[a-zA-Z0-9_-]{1,160}$/.test(value))fail('INVALID_ID');return value;}
function str(value,max=2000){if(typeof value!=='string'||value.length<1||value.length>max)fail('INVALID_FIELD');return value;}
function image(value){str(value,250000);if(!/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value))fail('IMAGE_DATA_REQUIRED');return value;}
function safeUrl(value,protocols){let url;try{url=new URL(value);}catch{fail('UPSTREAM_SCHEMA',502);}if(!protocols.includes(url.protocol)||url.username||url.password)fail('UPSTREAM_SCHEMA',502);return url.href;}
function upstreamString(value){if(typeof value!=='string'||!value.length||value.length>16384)fail('UPSTREAM_SCHEMA',502);return value;}
function validate(provider,params){
 object(params);
 if(provider==='decart'){
  exact(params,['model']);if(!providerById(provider).models.includes(params.model))fail('UNSUPPORTED_MODEL');
 }else if(provider==='liveavatar'){
  exact(params,['avatarId']);id(params.avatarId);
 }else if(provider==='tavus'){
  exact(params,['faceId','palId','context']);id(params.faceId);id(params.palId);if(params.context!==undefined)str(params.context);
 }else if(provider==='fashn'){
  exact(params,['personImage','garmentImage']);image(params.personImage);image(params.garmentImage);
 }
}
export class CloudService {
 #fetch;#credential;#sessions=new Map();#timeout;#closed=false;#pending=new Set();
 constructor({fetchImpl=globalThis.fetch,credential=(name)=>process.env[name],timeoutMs=15000}={}){
  this.#fetch=fetchImpl;this.#credential=credential;this.#timeout=timeoutMs;
 }
 catalog(){return PROVIDERS.map(p=>({...p,configured:!!(p.credentialEnv&&this.#credential(p.credentialEnv)),verified:false,mediaConnected:false}));}
 async #request(url,{method='POST',key,body,bearer=false}={}){
  // 响应读取同样受超时和字节上限约束；绝不转发厂商错误体，以免泄露密钥/素材。
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),this.#timeout);timer.unref?.();
  try{
   const response=await this.#fetch(url,{method,redirect:'error',signal:controller.signal,headers:{'Content-Type':'application/json',...(bearer?{Authorization:`Bearer ${key}`}:{'X-API-KEY':key})},...(body===undefined?{}:{body:JSON.stringify(body)})});
   if(!response.ok){await response.body?.cancel();fail(response.status===401||response.status===403?'UPSTREAM_AUTH':response.status===402?'UPSTREAM_CREDITS':response.status===429?'UPSTREAM_RATE_LIMIT':'UPSTREAM_ERROR',502);}
   if(response.status===204)return {};
   const reader=response.body?.getReader();if(!reader)fail('UPSTREAM_SCHEMA',502);
   const chunks=[];let size=0;
   while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>1024*1024){await reader.cancel();fail('UPSTREAM_RESPONSE_LIMIT',502);}chunks.push(value);}
   const text=Buffer.concat(chunks).toString();if(!text)return {};
   try{return JSON.parse(text);}catch{fail('UPSTREAM_SCHEMA',502);}
  }catch(error){if(error instanceof CloudError)throw error;fail(controller.signal.aborted?'UPSTREAM_TIMEOUT':'UPSTREAM_NETWORK',502);}
  finally{clearTimeout(timer);}
 }
 #get(sessionId){const s=this.#sessions.get(sessionId);if(!s)fail('SESSION_NOT_FOUND',404);return s;}
 snapshot(sessionId){const s=this.#get(sessionId);return {id:s.id,provider:s.provider,state:s.state,maxSeconds:s.maxSeconds,createdAt:s.createdAt,error:s.error??null,remoteMayBeActive:s.remoteMayBeActive,mediaConnected:false,outputActive:false};}
 async create(request,origin){
  const pending=this.#create(request,origin);this.#pending.add(pending);
  try{return await pending;}finally{this.#pending.delete(pending);}
 }
 async #create(request,origin){
  if(this.#closed)fail('SERVICE_CLOSED',503);
  exact(request,['provider','params','consent','maxSeconds']);
  const provider=providerById(request.provider);if(!provider)fail('UNKNOWN_PROVIDER');if(provider.adapter!=='control-plane')fail('ADAPTER_NOT_IMPLEMENTED',501);
  exact(request.consent,['cloudProcessing','billing']);if(request.consent.cloudProcessing!==true||request.consent.billing!==true)fail('CONSENT_REQUIRED',403);
  const maxSeconds=request.maxSeconds??120;if(!Number.isInteger(maxSeconds)||maxSeconds<10||maxSeconds>600)fail('INVALID_DURATION');
  const params=request.params;validate(provider.id,params);
  if(!/^http:\/\/127\.0\.0\.1:\d+$/.test(origin))fail('INVALID_ORIGIN',403);
  const key=this.#credential(provider.credentialEnv);if(typeof key!=='string'||!key.trim())fail('CREDENTIAL_MISSING',409);
  // 首版每宿主最多一项未结束工作；失败且无法确认结束时阻止重复创建计费任务。
  if([...this.#sessions.values()].some(s=>!['stopped','completed','failed'].includes(s.state)))fail('SESSION_BUSY',409);
  if(this.#sessions.size>=32){const old=[...this.#sessions.values()].find(s=>['stopped','completed','failed'].includes(s.state));if(old)this.#sessions.delete(old.id);}
  const s={id:randomUUID(),provider:provider.id,key,maxSeconds,createdAt:new Date().toISOString(),state:'creating',remoteMayBeActive:true};this.#sessions.set(s.id,s);
  let connection;
  try{
   if(provider.id==='decart'){
    const data=await this.#request('https://api.decart.ai/v1/client/tokens',{key,body:{expiresIn:60,allowedModels:[params.model],allowedOrigins:[origin],constraints:{realtime:{maxSessionDuration:maxSeconds}}}});
    connection={type:'decart-token',token:upstreamString(data.token),apiKey:upstreamString(data.apiKey),expiresAt:upstreamString(data.expiresAt),model:params.model};
    s.expiry=Date.parse(connection.expiresAt)+maxSeconds*1000;if(!Number.isFinite(s.expiry))fail('UPSTREAM_SCHEMA',502);
    s.state='token_ready';s.remoteMayBeActive=false;
   }else if(provider.id==='liveavatar'){
    const token=await this.#request('https://api.liveavatar.com/v1/sessions/token',{key,body:{mode:'LITE',avatar_id:params.avatarId,max_session_duration:maxSeconds}});
    if(token.code!==100)fail('UPSTREAM_ERROR',502);
    s.remoteId=upstreamString(token.data?.session_id);s.sessionToken=upstreamString(token.data?.session_token);
    const result=await this.#request('https://api.liveavatar.com/v1/sessions/start',{key:s.sessionToken,bearer:true});if(result.code!==100)fail('UPSTREAM_ERROR',502);const d=object(result.data);
    connection={type:'livekit',url:safeUrl(d.livekit_url,['wss:']),clientToken:upstreamString(d.livekit_client_token),...(d.ws_url?{controlUrl:safeUrl(d.ws_url,['wss:'])}:{})};s.state='awaiting_media';
   }else if(provider.id==='tavus'){
    const d=await this.#request('https://tavusapi.com/v2/conversations',{key,body:{face_id:params.faceId,pal_id:params.palId,...(params.context?{conversational_context:params.context}:{}),require_auth:true,properties:{max_call_duration:maxSeconds,participant_left_timeout:20,participant_absent_timeout:30,enable_recording:false}}});
    s.remoteId=upstreamString(d.conversation_id);connection={type:'daily',url:safeUrl(d.conversation_url,['https:']),meetingToken:upstreamString(d.meeting_token)};s.state='awaiting_media';
   }else{
    const d=await this.#request('https://api.fashn.ai/v1/run',{key,bearer:true,body:{model_name:'tryon-v1.6',inputs:{model_image:params.personImage,garment_image:params.garmentImage,num_samples:1,output_format:'png'}}});
    s.remoteId=upstreamString(d.id);connection={type:'image-job'};s.state='processing';
   }
   s.timer=setTimeout(()=>{void this.stop(s.id).catch(()=>{});},(provider.id==='decart'?maxSeconds+60:maxSeconds)*1000);s.timer.unref?.();
   return {...this.snapshot(s.id),connection};
  }catch(error){
   s.error=error instanceof CloudError?error.code:'UPSTREAM_SCHEMA';s.state='creation_unknown';
   if(s.remoteId&&provider.id!=='fashn'){try{await this.stop(s.id);}catch{}}
   // 身份拒绝/明确限流不会创建任务；网络和协议错误可能发生在远端创建之后。
   else if(['UPSTREAM_AUTH','UPSTREAM_CREDITS','UPSTREAM_RATE_LIMIT'].includes(s.error)){s.state='failed';s.remoteMayBeActive=false;}
   const err=new CloudError(s.error,502);err.sessionId=s.id;throw err;
  }
 }
 async poll(sessionId){
  const s=this.#get(sessionId);if(s.provider!=='fashn'||!s.remoteId)fail('POLL_UNSUPPORTED',409);
  if(['completed','failed'].includes(s.state))return this.snapshot(s.id);
  if(s.polling)fail('POLL_BUSY',409);s.polling=true;
  try{
   const d=await this.#request(`https://api.fashn.ai/v1/status/${encodeURIComponent(s.remoteId)}`,{method:'GET',key:s.key,bearer:true});
   if(!['starting','in_queue','processing','completed','failed'].includes(d.status))fail('UPSTREAM_SCHEMA',502);
   if(d.status==='completed'){
    if(!Array.isArray(d.output)||d.output.length!==1)fail('UPSTREAM_SCHEMA',502);
    const output=d.output.map(value=>safeUrl(value,['https:']));s.state='completed';s.remoteMayBeActive=false;clearTimeout(s.timer);return {...this.snapshot(s.id),output};
   }
   if(d.status==='failed'){s.state='failed';s.remoteMayBeActive=false;s.error='GENERATION_FAILED';clearTimeout(s.timer);}
   return this.snapshot(s.id);
  }finally{s.polling=false;}
 }
 async stop(sessionId){
  const s=this.#get(sessionId);if(s.state==='creating')fail('CREATE_IN_PROGRESS',409);
  if(['stopped','completed','failed'].includes(s.state))return this.snapshot(s.id);
  if(s.stopping)return s.stopping;
  clearTimeout(s.timer);
  s.stopping=(async()=>{
   if(s.provider==='decart'){
    // 发出去的短期令牌不可撤销。不能把本地 stop 伪装成对已连接远端的终止确认。
    const expiry=s.expiry??Date.now()+(60+s.maxSeconds)*1000;
    if(Date.now()<expiry){s.state='client_disconnect_required';s.remoteMayBeActive=true;s.timer=setTimeout(()=>{s.state='stopped';s.remoteMayBeActive=false;},expiry-Date.now());s.timer.unref?.();return this.snapshot(s.id);}
    s.state='stopped';s.remoteMayBeActive=false;return this.snapshot(s.id);
   }
   if(s.provider==='fashn'){s.state='remote_job_pending';s.remoteMayBeActive=true;return this.snapshot(s.id);}
   if(!s.remoteId){s.state='creation_unknown';fail('REMOTE_STATE_UNKNOWN',409);}
   s.state='stopping';
   try{
    if(s.provider==='liveavatar'){
     const result=await this.#request('https://api.liveavatar.com/v1/sessions/stop',{key:s.key,body:{session_id:s.remoteId,reason:'USER_CLOSED'}});
     if(result.code!==100)fail('UPSTREAM_ERROR',502);
    }
    else await this.#request(`https://tavusapi.com/v2/conversations/${encodeURIComponent(s.remoteId)}/end`,{key:s.key});
    s.state='stopped';s.remoteMayBeActive=false;s.sessionToken=undefined;return this.snapshot(s.id);
   }catch(error){s.state='cleanup_failed';s.error=error.code;throw error;}
  })();
  try{return await s.stopping;}finally{s.stopping=null;}
 }
 async close(){this.#closed=true;await Promise.allSettled([...this.#pending]);return Promise.allSettled([...this.#sessions.values()].map(async s=>{try{return await this.stop(s.id);}finally{clearTimeout(s.timer);}}));}
}
