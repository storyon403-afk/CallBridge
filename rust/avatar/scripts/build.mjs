// 本文件的目的：构建最小离线原型，只复制当前 full 模型所需文件，保留数值精度。
import {build} from 'esbuild';
import {readFile,writeFile,mkdir,copyFile,readdir,stat} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
const root=fileURLToPath(new URL('..',import.meta.url)), out=path.resolve(root,'../build/avatar');
const assets=path.resolve(root,'../build/avatar-assets');
for(const dir of ['vendor/holistic','model','fixtures','licenses','backgrounds'])await mkdir(path.join(out,dir),{recursive:true});
await copyFile(path.join(root,'backgrounds/aurora.mp4'),path.join(out,'backgrounds/aurora.mp4'));
const manifest=JSON.parse(await readFile(path.join(root,'assets.lock.json'),'utf8'));
for(const file of manifest.files){
 const data=await readFile(path.join(assets,file.name));
 if(data.length!==file.bytes||createHash('sha256').update(data).digest('hex')!==file.sha256)throw Error('资源校验失败：'+file.name);
 await writeFile(path.join(out,file.name==='sample.vrm'?'model/sample.vrm':file.name==='pose.jpg'?'fixtures/pose.jpg':file.name),data);
}
await writeFile(path.join(out,'assets.json'),JSON.stringify(manifest));
const result=await build({entryPoints:[path.join(root,'src/app.mjs')],outfile:path.join(out,'app.js'),bundle:true,minify:true,format:'esm',target:'es2022',metafile:true,legalComments:'linked'});
await writeFile(path.resolve(root,'../build/avatar-build-meta.json'),JSON.stringify(result.metafile));
for(const file of ['index.html','style.css','THIRD_PARTY.txt'])await copyFile(path.join(root,file),path.join(out,file));
const media=path.join(root,'node_modules/@mediapipe/holistic');
// modelComplexity 固定 1；不带未使用的 lite/heavy，也不改已使用模型的任何权重。
const files=['holistic.js','holistic.binarypb','holistic_solution_packed_assets.data','holistic_solution_packed_assets_loader.js','pose_landmark_full.tflite',
 'holistic_solution_simd_wasm_bin.data','holistic_solution_simd_wasm_bin.js','holistic_solution_simd_wasm_bin.wasm','holistic_solution_wasm_bin.js','holistic_solution_wasm_bin.wasm'];
for(const file of files)await copyFile(path.join(media,file),path.join(out,'vendor/holistic',file));
for(const [source,name] of [['node_modules/three/LICENSE','three.txt'],['node_modules/@pixiv/three-vrm/LICENSE','three-vrm.txt'],['licenses/Kalidokit-MIT.txt','kalidokit.txt']])await copyFile(path.join(root,source),path.join(out,'licenses',name));
async function bytes(dir){let total=0;for(const entry of await readdir(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);total+=entry.isDirectory()?await bytes(file):(await stat(file)).size;}return total;}
const report={runtimeBytes:await bytes(out),trackingBytes:await bytes(path.join(out,'vendor/holistic')),trackingPackageBytes:await bytes(media),modelBytes:manifest.files.find(f=>f.name==='sample.vrm').bytes,appJsBytes:(await stat(path.join(out,'app.js'))).size,appJsGzipBytes:gzipSync(await readFile(path.join(out,'app.js'))).length,nodeModulesBytes:await bytes(path.join(root,'node_modules')),modelComplexity:1,quantizationChanged:false};
await writeFile(path.resolve(root,'../build/avatar-size.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
