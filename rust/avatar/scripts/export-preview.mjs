// 本文件的目的：从现有角色的真实最终画布导出轻量目录预览，不下载模型或访问个人设备。
// 仅维护预览时显式运行；用户查看随 App 提供的图片不启动浏览器、推理或媒体服务。
import {chromium} from 'playwright-core';
import {fileURLToPath} from 'node:url';
import {startServer} from './server.mjs';
const server=await startServer(0),origin=`http://127.0.0.1:${server.address().port}`;
let browser;
try {
 browser=await chromium.launch({executablePath:process.env.CB_AVATAR_BROWSER??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const context=await browser.newContext({viewport:{width:800,height:700},permissions:[]});
 await context.route('**/*',route=>route.request().url().startsWith(origin+'/')?route.continue():route.abort());
 await context.addInitScript(()=>{navigator.mediaDevices.getUserMedia=()=>Promise.reject(Error('预览导出禁止设备采集'));});
 const page=await context.newPage();await page.goto(origin);
 await page.waitForFunction(()=>window.avatarLab?.stats.ready,{},{timeout:60000});
 await page.locator('#output').screenshot({path:fileURLToPath(new URL('../preview.jpg',import.meta.url)),type:'jpeg',quality:82});
 console.log('已导出原角色画布 preview.jpg；无相机、麦克风或虚拟输出');
} finally {await browser?.close();await new Promise(resolve=>server.close(resolve));}
