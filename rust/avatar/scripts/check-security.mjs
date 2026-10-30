// 本文件的目的：用纯内存设备替身检查 localhost 授权、路径逃逸及会话隔离，不调用任何发送器。
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,mkdir,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import http from 'node:http';
const folder=await mkdtemp(path.join(tmpdir(),'cb-http-security-'));await mkdir(path.join(folder,'site'));await writeFile(path.join(folder,'site/index.html'),'test');await writeFile(path.join(folder,'private.txt'),'must not leak');await symlink(path.join(folder,'private.txt'),path.join(folder,'site/link.txt'));
process.env.CB_AVATAR_ASSETS=path.join(folder,'site');
const {startServer}=await import('./server.mjs');let starts=0;
const camera={owner:null,session:null,status:async()=>({installed:false}),start:async()=>{starts++;throw Error('no device');},stop:async()=>false};
const server=await startServer(0,{camera}),origin=`http://127.0.0.1:${server.address().port}`;const checks=[];
try{
 assert.equal((await fetch(origin)).status,200);
 // Node fetch 会重写 Host，使用原始 HTTP 客户端才能实际发送伪造的主机名。
 const badHost=await new Promise((resolve,reject)=>{http.get(origin,{headers:{Host:'attacker.example'}},res=>{res.resume();resolve(res.statusCode);}).on('error',reject);});
 assert.equal(badHost,403);
 for(const resource of ['/','/camera/info','/background/custom','/character/info'])assert.equal((await fetch(origin+resource,{headers:{Origin:'https://attacker.example'}})).status,403);
 assert.equal((await fetch(origin+'/camera/info',{headers:{'Sec-Fetch-Site':'cross-site'}})).status,403);checks.push('Host/Origin/Fetch-Metadata guards cover assets and tokens');
 for(const resource of ['/link.txt','/..%2fprivate.txt','/%00','/a%5cb'])assert.equal((await fetch(origin+resource)).status,404);checks.push('Traversal, symlink escape, NUL and backslash rejected');
 const info=await(await fetch(origin+'/camera/info')).json();
 assert.match(info.token,/^[a-f0-9]{64}$/);
 const post=(headers,body)=>fetch(origin+'/camera/start',{method:'POST',headers:{'Content-Type':'application/json',...headers},body});
 assert.equal((await post({Origin:origin,'X-CB-Token':'wrong'},'{"confirm":true}')).status,403);
 assert.equal((await post({Origin:origin,'X-CB-Token':info.token},'{}')).status,403);
 assert.equal(starts,0);checks.push('No output starts without token and explicit confirmation');
 const response=await fetch(origin);assert.match(response.headers.get('Content-Security-Policy'),/frame-ancestors 'none'/);assert.match(response.headers.get('Permissions-Policy'),/microphone=\(\)/);
 console.log(JSON.stringify({passed:true,checks,deviceStarts:starts}));
}finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(folder,{recursive:true,force:true});}
