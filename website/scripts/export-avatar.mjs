// 本文件的目的：从现有角色渲染器生成合成动作视频，用于产品展示；禁止真实媒体设备和外联。
// 输出不是实测跟踪/通话录像。浏览器和模型仅用于维护素材，不进入网站发布包。
import {chromium} from '../../rust/avatar/node_modules/playwright-core/index.mjs';
import {startServer} from '../../rust/avatar/scripts/server.mjs';
import {fileURLToPath} from 'node:url';
import {mkdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
const folder=fileURLToPath(new URL('../media/',import.meta.url)),temp=fileURLToPath(new URL('../../build/site-export/',import.meta.url));await mkdir(temp,{recursive:true});
const server=await startServer(0,{camera:{status:async()=>({installed:false}),stop:async()=>true}}),origin=`http://127.0.0.1:${server.address().port}`;
let browser;
try{
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const context=await browser.newContext({viewport:{width:860,height:800},permissions:[]});
 await context.route('**/*',r=>r.request().url().startsWith(origin+'/')?r.continue():r.abort());
 await context.addInitScript(()=>{window.callbridgeComposition={person:'avatar',background:'parallax'};navigator.mediaDevices.getUserMedia=()=>{throw Error('展示导出禁止设备采集');};});
 const page=await context.newPage();await page.goto(origin);await page.waitForFunction(()=>avatarLab.stats.ready,{},{timeout:60000});
 await page.evaluate(()=>avatarLab.demo());
 await page.locator('#output').screenshot({path:folder+'avatar-poster.jpg',type:'jpeg',quality:85});
 const base64=await page.evaluate(async()=>{
  const stream=document.querySelector('#output').captureStream(24),chunks=[],recorder=new MediaRecorder(stream,{mimeType:'video/webm;codecs=vp9',videoBitsPerSecond:1800000});
  const done=new Promise(resolve=>{recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data);};recorder.onstop=async()=>{stream.getTracks().forEach(t=>t.stop());const reader=new FileReader();reader.onload=()=>resolve(reader.result.split(',')[1]);reader.readAsDataURL(new Blob(chunks,{type:'video/webm'}));};});
  recorder.start();setTimeout(()=>recorder.stop(),6500);return done;
 });
 await writeFile(temp+'avatar.webm',Buffer.from(base64,'base64'));
 execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y','-i',temp+'avatar.webm','-an','-vf','scale=800:-2,format=yuv420p','-c:v','libx264','-preset','slow','-crf','23','-movflags','+faststart',folder+'avatar-motion.mp4']);
 console.log('Exported synthetic avatar motion and poster. No physical media or device output.');
}finally{await browser?.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
