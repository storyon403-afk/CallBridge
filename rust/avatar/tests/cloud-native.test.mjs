// 用内存服务/管道验证原生桥，不读取真实密钥，不联系厂商或启动媒体。
import test from 'node:test';
import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import {nativeCommand,runNativeHost} from '../scripts/cloud/native-host.mjs';
import {CloudService} from '../scripts/cloud/service.mjs';
const create={id:1,op:'create',body:{provider:'fashn',params:{personImage:'data:image/png;base64,YQ==',garmentImage:'data:image/png;base64,Yg=='},maxSeconds:120,consent:{cloudProcessing:true,billing:true}}};
const tick=()=>new Promise(r=>setImmediate(r));
function fixture(replies=[]){const calls=[];const service=new CloudService({credential:()=> 'fixture-secret',fetchImpl:async(url,options)=>{calls.push({url,options});const next=replies.shift();if(next instanceof Error)throw next;return new Response(JSON.stringify(next));}});return {service,calls};}
test('原生目录与无媒体引擎不发起上游调用',async()=>{
 const {service,calls}=fixture();assert.equal((await nativeCommand(service,{id:1,op:'catalog'})).providers.length,8);
 for(const provider of ['decart','liveavatar','tavus','zego'])await assert.rejects(nativeCommand(service,{...create,body:{...create.body,provider}}),{code:'MEDIA_NOT_CONNECTED'});
 for(const request of [{id:0,op:'catalog'},{id:1,op:'catalog',credential:'x'},{id:1,op:'unknown'}])await assert.rejects(nativeCommand(service,request));
 assert.equal(calls.length,0);await service.close();
});
test('图片任务复用服务契约、去掉连接凭据、停止保留远端状态',async()=>{
 const {service,calls}=fixture([{id:'remote'},{status:'completed',output:['https://cdn.fashn.ai/result.png']}]);
 const job=await nativeCommand(service,create);assert.equal(job.state,'processing');assert.equal('connection' in job,false);assert.equal(JSON.stringify(job).includes('fixture-secret'),false);
 await assert.rejects(nativeCommand(service,{...create,id:2}),{code:'SESSION_BUSY'});assert.equal(calls.length,1);
 assert.equal((await nativeCommand(service,{id:3,op:'stop',sessionId:job.id})).remoteMayBeActive,true);
 const result=await nativeCommand(service,{id:4,op:'poll',sessionId:job.id});assert.equal(result.state,'completed');assert.equal(result.remoteMayBeActive,false);await service.close();
});
test('未确认上传与计费时在本地拒绝',async()=>{const {service,calls}=fixture();await assert.rejects(nativeCommand(service,{...create,body:{...create.body,consent:{cloudProcessing:false,billing:false}}}),{code:'CONSENT_REQUIRED'});assert.equal(calls.length,0);await service.close();});
test('分块管道、有界输入和忙状态均不重放创建',async()=>{
 const input=new PassThrough(),output=new PassThrough();let data='',release;output.on('data',b=>data+=b);let count=0,closed=0;
 const ready=new Promise(r=>release=r);const service={catalog:()=>[],create:async()=>{count++;await ready;return {id:'local',state:'processing',connection:{token:'fixture-secret'}};},close:async()=>{closed++;}};
 const close=runNativeHost(input,output,service);const bytes=JSON.stringify(create)+'\n';input.write(bytes.slice(0,18));assert.equal(count,0);input.write(bytes.slice(18));input.write(JSON.stringify({...create,id:2})+'\n');await tick();assert.equal(count,1);assert.match(data,/HOST_BUSY/);release();await tick();assert.equal(data.includes('fixture-secret'),false);await close();assert.equal(closed,1);
 const large=new PassThrough(),sink=new PassThrough();sink.resume();let limitClosed=false;runNativeHost(large,sink,{close:async()=>{limitClosed=true;}});large.write(Buffer.alloc(512*1024+1));await tick();assert.ok(limitClosed);
});
test('创建错误保留本地快照且不泄露远端错误内容',async()=>{
 const {service}=fixture([new Error('secret provider response')]);const input=new PassThrough(),output=new PassThrough();let text='';output.on('data',b=>text+=b);const close=runNativeHost(input,output,service);
 input.write(JSON.stringify(create)+'\n');await tick();await tick();const response=JSON.parse(text);assert.equal(response.error,'UPSTREAM_NETWORK');assert.equal(response.result.state,'creation_unknown');assert.ok(response.result.remoteMayBeActive);assert.equal(text.includes('secret provider'),false);await close();
});
test('独立原生宿主可握手并在 stdin 关闭后退出，不继承账号',async()=>{
 const {spawn}=await import('node:child_process');
 const child=spawn(process.execPath,[new URL('../scripts/cloud/native-host.mjs',import.meta.url).pathname],{env:{PATH:process.env.PATH},stdio:['pipe','pipe','pipe']});
 let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);
 const finished=new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});
 child.stdin.end(JSON.stringify({id:1,op:'catalog'})+'\n');
 assert.equal(await finished,0);assert.equal(err,'');const result=JSON.parse(out);assert.equal(result.result.providers.length,8);assert.ok(result.result.providers.every(p=>!p.configured));
});
