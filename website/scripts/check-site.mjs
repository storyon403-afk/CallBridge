// 本文件的目的：核对展示位、现有素材、键盘切换及手机布局；不打开任何设备。
import {chromium} from '../../rust/avatar/node_modules/playwright-core/index.mjs';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('../../build/site/',import.meta.url)),out=fileURLToPath(new URL('../../build/site-check/',import.meta.url)),assets=fileURLToPath(new URL('../../assets/demos/',import.meta.url));await mkdir(out,{recursive:true});
const types={'.html':'text/html','.css':'text/css','.js':'text/javascript','.png':'image/png','.jpg':'image/jpeg','.mp4':'video/mp4'};
const server=createServer(async(req,res)=>{try{const url=new URL(req.url,'http://localhost');if(!url.pathname.startsWith('/CallBridge/'))throw Error('prefix');const relative=decodeURIComponent(url.pathname.slice(12))||'index.html',file=path.resolve(root,relative);if(!file.startsWith(root))throw Error('path');const data=await readFile(file);const m=/^bytes=(\d+)-(\d*)$/.exec(req.headers.range??'');let start=0,end=data.length-1;if(m){start=Number(m[1]);end=Math.min(end,m[2]?Number(m[2]):end);}if(start>end){res.writeHead(416);return res.end();}const headers={'Content-Type':types[path.extname(file)]??'application/octet-stream','Accept-Ranges':'bytes','Content-Length':end-start+1};if(m)headers['Content-Range']=`bytes ${start}-${end}/${data.length}`;res.writeHead(m?206:200,headers);res.end(data.subarray(start,end+1));}catch{res.writeHead(404);res.end();}});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;const errors=[],failed=[],checks=[];
try{
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const origin=`http://127.0.0.1:${server.address().port}/CallBridge/`;
 const context=await browser.newContext({viewport:{width:1440,height:1000},permissions:[]});
 await context.addInitScript(()=>{navigator.mediaDevices.getUserMedia=()=>{throw Error('Website must not open devices');};});
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.status()>=400)failed.push([r.url(),r.status()]);});
 await page.goto(origin);await page.waitForFunction(()=>document.querySelectorAll('[role=tab]').length===7);
 for(const width of [1440,768,375,320]){
  await page.setViewportSize({width,height:1000});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`overflow ${width}`);
  if(width===375)await page.screenshot({path:out+'mobile.png',fullPage:true});
 }
 checks.push('Chinese layout: 1440 / 768 / 375 / 320 px');
 await page.setViewportSize({width:1440,height:1000});await page.evaluate(()=>scrollTo({top:0,behavior:'instant'}));
 await page.screenshot({path:out+'desktop.png',fullPage:true});
 await page.locator('#tab-experience').click();
 await page.locator('.experience-viewport').scrollIntoViewIfNeeded();
 await page.locator('.experience-window').evaluateAll(images=>Promise.all(images.map(img=>img.decode())));
 assert.deepEqual(await page.locator('.experience-window').evaluateAll(images=>images.map(img=>img.getAttribute('src'))),['media/ui-main.png','media/ui-video.png','media/ui-text.png']);
 await page.locator('.experience-steps button').nth(3).click();
 assert.equal(await page.locator('.experience-scene').getAttribute('data-step'),'3');
 await page.waitForTimeout(850); // 等待窗口位置过渡结束后再保存展示截图。
 await page.screenshot({path:out+'experience.png',fullPage:true});
 await page.locator('.experience-replay').click();
 await page.waitForFunction(()=>document.querySelector('.experience-scene')?.dataset.step==='1',{},{timeout:10000}).catch(async error=>{console.error(await page.evaluate(()=>({hidden:document.hidden,step:document.querySelector('.experience-scene')?.dataset.step,play:document.querySelector('.experience-play')?.textContent,rect:document.querySelector('.experience')?.getBoundingClientRect().toJSON(),height:innerHeight})));throw error});
 await page.locator('.experience-play').click();
 const paused=await page.locator('.experience-scene').getAttribute('data-step');await page.waitForTimeout(2800);
 assert.equal(await page.locator('.experience-scene').getAttribute('data-step'),paused);
 checks.push('Native window assets load; experience steps, replay and pause work');
 for(const id of ['speech','background-audio','ambient']){
  await page.locator('#tab-'+id).click();assert.equal(await page.locator('#media-panel video').count(),2);
  assert.equal(await page.locator('.result video').evaluate(v=>v.paused),true);
  await page.locator('.workflow video').evaluate(v=>new Promise((resolve,reject)=>{v.preload='auto';v.onloadeddata=()=>resolve(true);v.onerror=()=>reject(Error('video failed'));v.load();}));
 }
 checks.push('Three existing paired recordings load; no autoplay');
 await page.locator('#tab-voice').click();await page.locator('.single-media img').evaluate(img=>img.decode());
 for(const id of ['avatar','background']){
  await page.locator('#tab-'+id).click();assert.equal(await page.locator('.placeholder-label').innerText(),'待添加');assert.equal(await page.locator('#media-panel video').count(),0);
 }
 checks.push('Screenshot displays; empty slots contain no fake players');
 await page.locator('#tab-background').press('Home');assert.equal(await page.locator('#tab-experience').getAttribute('aria-selected'),'true');
 await page.locator('#tab-experience').press('ArrowRight');assert.equal(await page.locator('#tab-speech').getAttribute('aria-selected'),'true');
 await page.locator('#language').click();assert.equal(await page.locator('html').getAttribute('lang'),'en');
 for(const width of [1440,375,320]){await page.setViewportSize({width,height:1000});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`English overflow ${width}`);}
 await page.reload();assert.equal(await page.locator('html').getAttribute('lang'),'en');checks.push('Keyboard tabs and English persistence');
 await page.locator('.experience-window').evaluateAll(images=>Promise.all(images.map(img=>img.decode())));
 assert.deepEqual(await page.locator('.experience-window').evaluateAll(images=>images.map(img=>img.getAttribute('src'))),['media/ui-en-main.png','media/ui-en-video.png','media/ui-en-text.png']);
 await page.setViewportSize({width:1440,height:1000});await page.locator('.experience-steps button').nth(4).click();await page.waitForTimeout(850);
 await page.locator('#media-panel').screenshot({path:out+'experience-en.png'});
 checks.push('English experience uses English native panels after language selection and reload');
 // 通过同一素材接口填入新条目，确认展示位能直接接视频，不需要改 HTML。
 await page.evaluate(()=>CALLBRIDGE_SHOWCASE.push({id:'test-upload',title:{zh:'新展示',en:'New demo'},type:'video',src:'media/effect-01.mp4'}));
 await page.locator('#language').click();assert.equal(await page.locator('.experience-main').getAttribute('src'),'media/ui-main.png');await page.locator('#tab-test-upload').click();assert.equal(await page.locator('.single-media video').count(),1);assert.equal(await page.locator('.single-media video').evaluate(v=>v.paused),true);
 checks.push('New media slot can be supplied through content.js');
 const reduced=await browser.newContext({viewport:{width:1000,height:800},reducedMotion:'reduce',permissions:[]});const rp=await reduced.newPage();await rp.goto(origin);assert.equal(await rp.locator('html').evaluate(el=>getComputedStyle(el).scrollBehavior),'auto');await rp.locator('#tab-experience').click();assert.equal(await rp.locator('.experience-play').innerText(),'播放');checks.push('Reduced motion starts experience paused');
 assert.deepEqual(errors,[]);assert.deepEqual(failed,[]);const report={passed:true,checks,errors,failed,physicalMedia:false};await writeFile(out+'report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await browser?.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
