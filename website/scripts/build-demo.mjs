// 本文件的目的：生成网页专用角色渲染器与许可，只复制锁定原模型；不包含跟踪模型、私人资源或设备服务。
import {build} from '../../rust/avatar/node_modules/esbuild/lib/main.js';
import {readFile,writeFile,mkdir,copyFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url)),out=root+'website/media/';
await mkdir(out,{recursive:true});
const lock=JSON.parse(await readFile(root+'rust/avatar/assets.lock.json','utf8')),asset=lock.files.find(f=>f.name==='sample.vrm');
const model=await readFile(root+'rust/build/avatar-assets/sample.vrm');
if(model.length!==asset.bytes||createHash('sha256').update(model).digest('hex')!==asset.sha256)throw Error('模型校验失败');
await writeFile(out+'cheng.vrm',model);
await build({entryPoints:[root+'website/src/avatar-viewer.mjs'],outfile:out+'avatar-viewer.js',bundle:true,minify:true,format:'esm',target:'es2022',nodePaths:[root+'rust/avatar/node_modules'],legalComments:'linked'});
let notice='CallBridge website demo\n\nVRM1_Constraint_Twist_Sample (c) 2022 pixiv Inc.\n'+asset.url+'\nVRM Public License 1.0: https://vrm.dev/en/licenses/1.0/\nOriginal VRM bytes and License Settings are preserved. CallBridge adds its existing outfit at runtime. Preset motion is a demonstration, not camera tracking or a live call.\n\n';
for(const name of ['node_modules/three/LICENSE','node_modules/@pixiv/three-vrm/LICENSE','licenses/Kalidokit-MIT.txt'])notice+='\n'+name+'\n'+await readFile(root+'rust/avatar/'+name,'utf8');
await writeFile(out+'demo-licenses.txt',notice);
console.log('Website renderer and original model prepared; no tracking or private media.');
