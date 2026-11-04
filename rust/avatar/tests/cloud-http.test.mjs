// 本机集成测试只绑定回环地址并注入纯内存服务，不访问厂商或系统媒体设备。
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {CloudService} from '../scripts/cloud/service.mjs';
test('宿主云 API：令牌/来源校验、参数拒绝、会话结果不触发设备 I/O',async()=>{
 const build=fileURLToPath(new URL('../../build/',import.meta.url));await mkdir(build,{recursive:true});const folder=await mkdtemp(build+'cloud-http-');await writeFile(folder+'/index.html','test');process.env.CB_AVATAR_ASSETS=folder;
 const {startServer}=await import('../scripts/server.mjs');let upstream=0,deviceCalls=0;
 const cloud=new CloudService({credential:()=> 'fixture-key',fetchImpl:async()=>{upstream++;return new Response(JSON.stringify({token:'short',apiKey:'ephemeral',expiresAt:new Date(Date.now()+60000).toISOString()}));}});
 const camera={owner:null,status:async()=>{deviceCalls++;return {};},start:async()=>{deviceCalls++;},stop:async()=>false};
 const server=await startServer(0,{camera,cloud});const origin=`http://127.0.0.1:${server.address().port}`;
 try{
  assert.equal((await fetch(origin+'/cloud/v1/info',{headers:{Origin:'https://evil.example'}})).status,403);
  const {token}=await(await fetch(origin+'/cloud/v1/info')).json();assert.match(token,/^[a-f0-9]{64}$/);
  assert.equal((await fetch(origin+'/cloud/v1/providers')).status,403);
  const headers={'X-CB-Token':token,Origin:origin,'Content-Type':'application/json'};
  assert.equal((await(await fetch(origin+'/cloud/v1/providers',{headers})).json()).providers.length,8);
  const data={provider:'decart',params:{model:'lucy-vton-3.6'},consent:{cloudProcessing:true,billing:true},maxSeconds:120};
  assert.equal((await fetch(origin+'/cloud/v1/sessions',{method:'POST',headers:{...headers,Origin:'https://evil.example'},body:JSON.stringify(data)})).status,403);
  assert.equal((await fetch(origin+'/cloud/v1/sessions',{method:'POST',headers,body:'not json'})).status,400);
  assert.equal(upstream,0);
  const response=await fetch(origin+'/cloud/v1/sessions',{method:'POST',headers,body:JSON.stringify(data)});assert.equal(response.status,201);const created=await response.json();assert.equal(created.connection.type,'decart-token');
  const snapshot=await(await fetch(origin+'/cloud/v1/sessions/'+created.id,{headers})).json();assert.equal(snapshot.outputActive,false);assert.equal(snapshot.connection,undefined);assert.equal(deviceCalls,0);
  assert.equal((await(await fetch(origin+'/cloud/v1/sessions/'+created.id+'/stop',{method:'POST',headers})).json()).state,'client_disconnect_required');
  assert.equal((await fetch(origin+'/cloud/v1/anything',{headers})).status,404);assert.equal(upstream,1);
 }finally{await server.closeCloud();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(folder,{recursive:true});}
});
