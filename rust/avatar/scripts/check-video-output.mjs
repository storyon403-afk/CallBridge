// 本文件的目的：验证真实浏览器最终画布经过 HTTP/匿名管道转换为原生内存视频帧。
// 只通过构造参数注入 memoryOnly 发送器；不开物理摄像头，不启动任何虚拟设备。
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright-core';
import {CameraBridge} from './camera-bridge.mjs';
import {startServer} from './server.mjs';
const out=fileURLToPath(new URL('../../build/camera/',import.meta.url));
await mkdir(out,{recursive:true});
const camera=new CameraBridge({memoryOnly:true}),server=await startServer(0,{camera});
const origin=`http://127.0.0.1:${server.address().port}`,checks=[],external=[],errors=[];
let browser;
const deadline=setTimeout(()=>browser?.close(),90000);deadline.unref();
const until=async test=>{for(let i=0;i<100;i++){if(test())return;await new Promise(r=>setTimeout(r,20));}assert.fail('发送器未按时停止');};
try{
 const info=await (await fetch(origin+'/camera/info')).json();assert.equal(info.memoryOnly,true);assert.equal(camera.child,null);
 const owner=randomUUID(),headers={'Origin':origin,'X-CB-Token':info.token,'X-CB-Owner':owner,'Content-Type':'application/json'};
 const post=(url,extra={},body='{}')=>fetch(origin+url,{method:'POST',headers:{...headers,...extra},body});
 assert.equal((await post('/camera/start',{'Origin':'https://example.org'},'{"confirm":true}')).status,403);
 assert.equal((await post('/camera/start',{'X-CB-Token':'wrong'},'{"confirm":true}')).status,403);
 assert.equal((await post('/camera/start')).status,403);assert.equal(camera.child,null);checks.push('启动需要同源、令牌和主动确认');
 const started=await post('/camera/start',{},'{"confirm":true}');assert.equal(started.status,200);const session=(await started.json()).session;
 assert.equal((await post('/camera/start',{'X-CB-Owner':randomUUID()},'{"confirm":true}')).status,409);
 assert.equal((await post('/camera/frame',{'X-CB-Session':'expired'})).status,409);
 assert.equal((await post('/camera/frame',{'X-CB-Session':session})).status,400);
 assert.equal((await (await post('/camera/stop',{'X-CB-Owner':randomUUID()})).json()).stopped,false);
 assert.equal((await (await post('/camera/stop')).json()).stopped,true);assert.equal(camera.child,null);
 assert.equal((await post('/camera/frame',{'X-CB-Session':session})).status,409);checks.push('会话互斥、帧尺寸和停止后的迟到帧拒绝');
 await camera.start(owner);await until(()=>camera.child===null);assert.equal(camera.session,null);checks.push('无帧发送器超时退出');
 // 延迟路径解析可稳定复现“启动尚未完成就停止”，不依赖进程调度碰运气。
 const originalPath=camera.path.bind(camera);let release;
 camera.path=()=>new Promise(resolve=>{release=async()=>resolve(await originalPath());});
 const pending=camera.start(owner).then(()=>false,()=>true);await camera.stop(owner);await release();assert.equal(await pending,true);
 camera.path=originalPath;assert.equal(camera.child,null);checks.push('后端取消启动不产生迟到进程');
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const context=await browser.newContext({viewport:{width:1000,height:1000},permissions:[]});
 await context.route('**/*',route=>{if(route.request().url().startsWith(origin+'/'))return route.continue();external.push(route.request().url());return route.abort();});
 await context.addInitScript(()=>{window.mediaCalls=0;navigator.mediaDevices.getUserMedia=()=>{window.mediaCalls++;throw Error('本测试禁止开启设备');};});
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin);await page.waitForFunction(()=>window.avatarLab?.stats.ready&&avatarLab.videoOutput.installed);
 assert.equal(camera.child,null);await page.click('#demo');await page.click('#send-video');
 await page.waitForFunction(()=>avatarLab.videoOutput.lastResult?.accepted&&avatarLab.videoOutput.lastResult.sequence>=3);
 const result=await page.evaluate(()=>({ack:avatarLab.videoOutput.lastResult,mediaCalls,status:document.querySelector('#video-status').textContent}));
 assert.equal(result.mediaCalls,0);assert.equal(result.ack.memoryOnly,true);assert.equal(result.ack.bytes,1280*720*4);
 assert.deepEqual(result.ack.firstBGRA,[31,43,35,255]);assert.match(result.status,/内存帧检查/);
 await page.screenshot({path:out+'video-output.png'});checks.push('真实最终画布经 HTTP 与管道生成 720p BGRA CMSampleBuffer');
 await page.click('#stop-video');await until(()=>camera.child===null);assert.equal(camera.session,null);
 assert.equal(await page.evaluate(()=>avatarLab.videoOutput.active),false);checks.push('停止按钮撤销发送器和会话');
 // 延迟真实启动响应，让用户停止发生在服务器已建会话、前端尚未知晓之时。
 await page.route('**/camera/start',async route=>{const response=await route.fetch();await new Promise(r=>setTimeout(r,250));await route.fulfill({response});});
 await page.click('#send-video');await page.waitForFunction(()=>avatarLab.videoOutput.starting);await page.click('#stop-video');
 await page.waitForTimeout(450);await until(()=>camera.child===null);
 assert.equal(await page.evaluate(()=>avatarLab.videoOutput.active),false);await page.unroute('**/camera/start');checks.push('迟到启动响应不能恢复已停止的输出');
 await page.click('#send-video');await page.waitForFunction(()=>avatarLab.videoOutput.active);
 await page.evaluate(()=>window.dispatchEvent(new Event('pagehide')));await until(()=>camera.child===null);
 assert.equal(await page.evaluate(()=>avatarLab.videoOutput.active),false);checks.push('页面退出同步撤销输出');
 await page.setViewportSize({width:360,height:900});await page.screenshot({path:out+'video-narrow.png'});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);checks.push('窄屏无水平溢出');
 assert.deepEqual(external,[]);assert.deepEqual(errors,[]);
 const report={passed:true,checks,result,external,errors,physicalCameraOpened:false,virtualDeviceStarted:false};
 await writeFile(out+'video-output-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}catch(error){await writeFile(out+'video-output-report.json',JSON.stringify({passed:false,checks,error:String(error)},null,2));throw error;}
finally{clearTimeout(deadline);await browser?.close();await camera.stop(camera.owner);await new Promise(r=>server.close(r));}
