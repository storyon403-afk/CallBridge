// 使用内存 HTTP 替身验证云端协议、失效与清理边界；测试绝不使用真实密钥或调用厂商。
import test from 'node:test';
import assert from 'node:assert/strict';
import {CloudService} from '../scripts/cloud/service.mjs';
const origin='http://127.0.0.1:5778';
const consent={cloudProcessing:true,billing:true};
const req=(provider,params)=>({provider,params,consent,maxSeconds:120});
const response=(data,status=200)=>new Response(status===204?null:JSON.stringify(data),{status});
const fixture=(replies,extra={})=>{const calls=[];return {calls,service:new CloudService({credential:()=> 'test-only-secret',fetchImpl:async(url,opts)=>{calls.push({url,...opts,parsed:opts.body?JSON.parse(opts.body):undefined});const next=replies.shift();if(next instanceof Error)throw next;if(typeof next==='function')return next(url,opts);if(!next)throw Error('unexpected call');return next;},...extra})};};
test('目录不联网且待适配厂商不可调用',async()=>{
 const {service,calls}=fixture([]);assert.equal(service.catalog().length,8);assert.ok(service.catalog().every(p=>p.verified===false&&p.mediaConnected===false));
 await assert.rejects(service.create(req('zego',{}),origin),{code:'ADAPTER_NOT_IMPLEMENTED'});assert.equal(calls.length,0);
});
test('授权、未知字段、凭据、图片与模型检查均早于联网',async()=>{
 const {service,calls}=fixture([]);
 for(const request of [{...req('decart',{model:'lucy-vton-3.6'}),consent:{cloudProcessing:true,billing:false}},req('decart',{model:'other'}),req('fashn',{personImage:'http://127.0.0.1/private',garmentImage:'secret'}),{...req('liveavatar',{avatarId:'a'}),apiKey:'leak'},req('tavus',{faceId:'x',palId:'y',meeting_url:'https://meeting.example'})])await assert.rejects(service.create(request,origin));
 const empty=new CloudService({credential:()=>undefined});await assert.rejects(empty.create(req('liveavatar',{avatarId:'a'}),origin),{code:'CREDENTIAL_MISSING'});assert.equal(calls.length,0);
});
test('Decart 限定模型、Origin、令牌有效期与会话上限，不谎报可撤销',async()=>{
 const {service,calls}=fixture([response({token:'signed-test-token',apiKey:'ephemeral-test',expiresAt:new Date(Date.now()+60000).toISOString()})]);
 const s=await service.create(req('decart',{model:'lucy-vton-3.6'}),origin);assert.equal(s.state,'token_ready');assert.equal(calls[0].url,'https://api.decart.ai/v1/client/tokens');assert.deepEqual(calls[0].parsed.allowedOrigins,[origin]);assert.equal(calls[0].parsed.constraints.realtime.maxSessionDuration,120);
 assert.equal(JSON.stringify(service.snapshot(s.id)).includes('test-token'),false);assert.equal((await service.stop(s.id)).state,'client_disconnect_required');await service.close();
});
test('LiveAvatar 使用 Lite；只返回客户端凭据，stop 使用固定端点',async()=>{
 const {service,calls}=fixture([response({code:100,data:{session_id:'remote-one',session_token:'server-session-secret'}}),response({code:100,data:{livekit_url:'wss://room.livekit.cloud',livekit_client_token:'viewer-token',livekit_agent_token:'hidden-agent',ws_url:'wss://control.example'}}),response({code:100})]);
 const s=await service.create(req('liveavatar',{avatarId:'avatar-one'}),origin);assert.equal(calls[0].parsed.mode,'LITE');assert.equal(calls[1].headers.Authorization,'Bearer server-session-secret');assert.equal(s.state,'awaiting_media');assert.equal(JSON.stringify(s).includes('hidden-agent'),false);assert.equal(JSON.stringify(s).includes('server-session-secret'),false);
 assert.equal((await service.stop(s.id)).state,'stopped');assert.equal(calls[2].parsed.reason,'USER_CLOSED');assert.equal(calls[2].url,'https://api.liveavatar.com/v1/sessions/stop');await service.close();
});
test('启动失败后清理已分配 LiveAvatar；不暴露错误体',async()=>{
 const {service,calls}=fixture([response({code:100,data:{session_id:'remote-one',session_token:'server-session-secret'}}),response({error:'test-only-secret'},500),response({code:100})]);
 let caught;try{await service.create(req('liveavatar',{avatarId:'a'}),origin);}catch(e){caught=e;}
 assert.equal(caught.code,'UPSTREAM_ERROR');assert.equal(service.snapshot(caught.sessionId).state,'stopped');assert.equal(calls.length,3);assert.equal(caught.message.includes('secret'),false);await service.close();
});
test('Tavus 使用现行 face/pal 字段、私有房间、不录制，结束而非删除',async()=>{
 const {service,calls}=fixture([response({conversation_id:'c123',conversation_url:'https://tavus.daily.co/room',meeting_token:'meeting-token'}),response({},204)]);
 const s=await service.create(req('tavus',{faceId:'f123',palId:'p123'}),origin);assert.equal(calls[0].parsed.require_auth,true);assert.equal(calls[0].parsed.face_id,'f123');assert.equal(calls[0].parsed.properties.enable_recording,false);await service.stop(s.id);assert.equal(calls[1].url,'https://tavusapi.com/v2/conversations/c123/end');assert.equal(calls[1].method,'POST');await service.close();
});
test('FASHN 生成任务支持轮询；停止不伪装成远端已取消',async()=>{
 const {service,calls}=fixture([response({id:'job-one'}),response({status:'processing'}),response({status:'completed',output:['https://cdn.fashn.ai/result.png']})]);
 const s=await service.create(req('fashn',{personImage:'data:image/png;base64,YQ==',garmentImage:'data:image/png;base64,Yg=='}),origin);assert.equal(calls[0].parsed.model_name,'tryon-v1.6');assert.equal((await service.stop(s.id)).state,'remote_job_pending');assert.equal((await service.poll(s.id)).state,'remote_job_pending');const done=await service.poll(s.id);assert.equal(done.state,'completed');assert.deepEqual(done.output,['https://cdn.fashn.ai/result.png']);await service.close();
});
test('远端停止失败可重试；阻止叠加新计费会话',async()=>{
 const {service}=fixture([response({conversation_id:'c123',conversation_url:'https://tavus.daily.co/room',meeting_token:'m'}),new Error('secret network details'),response({},204)]);
 const s=await service.create(req('tavus',{faceId:'f',palId:'p'}),origin);await assert.rejects(service.stop(s.id),{code:'UPSTREAM_NETWORK'});assert.equal(service.snapshot(s.id).state,'cleanup_failed');await assert.rejects(service.create(req('tavus',{faceId:'f',palId:'p'}),origin),{code:'SESSION_BUSY'});assert.equal((await service.stop(s.id)).state,'stopped');await service.close();
});
test('创建超时保持未知状态，不自动重试与重复计费',async()=>{
 const {service,calls}=fixture([(_url,o)=>new Promise((_r,reject)=>o.signal.addEventListener('abort',()=>reject(new Error('aborted'))))],{timeoutMs:10});
 const keepAlive=setTimeout(()=>{},1000);
 try{let caught;try{await service.create(req('tavus',{faceId:'f',palId:'p'}),origin);}catch(e){caught=e;}assert.equal(caught.code,'UPSTREAM_TIMEOUT');assert.equal(service.snapshot(caught.sessionId).state,'creation_unknown');assert.equal(calls.length,1);}finally{clearTimeout(keepAlive);await service.close();}
});
test('主机关闭等待正在创建的会话完成后清理，不产生晚到的孤儿会话',async()=>{
 let release;const ready=new Promise(r=>{release=r;});
 const {service,calls}=fixture([async()=>{await ready;return response({conversation_id:'c1',conversation_url:'https://tavus.daily.co/room',meeting_token:'m'});},response({},204)]);
 const creation=service.create(req('tavus',{faceId:'f',palId:'p'}),origin);const closing=service.close();release();const s=await creation;await closing;assert.equal(service.snapshot(s.id).state,'stopped');assert.equal(calls.length,2);await assert.rejects(service.create(req('tavus',{faceId:'f',palId:'p'}),origin),{code:'SERVICE_CLOSED'});
});
test('超大响应和不安全返回 URL 被拒绝',async()=>{
 const {service}=fixture([response({payload:'x'.repeat(1024*1024)})]);await assert.rejects(service.create(req('decart',{model:'lucy-vton-3.6'}),origin),{code:'UPSTREAM_RESPONSE_LIMIT'});await service.close();
 const f=fixture([response({conversation_id:'c1',conversation_url:'javascript:alert(1)',meeting_token:'m'}),response({},204)]);await assert.rejects(f.service.create(req('tavus',{faceId:'f',palId:'p'}),origin),{code:'UPSTREAM_SCHEMA'});await f.service.close();
});
