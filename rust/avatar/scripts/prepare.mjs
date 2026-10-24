// 本文件的目的：按固定来源与 SHA256 准备测试资源；已有正确文件直接复用。
import {readFile,writeFile,mkdir,rename,unlink} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';import {createHash,randomUUID} from 'node:crypto';
import path from 'node:path';import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('..',import.meta.url)),target=path.resolve(root,'../build/avatar-assets');
await mkdir(target,{recursive:true});
const manifest=JSON.parse(await readFile(path.join(root,'assets.lock.json'),'utf8'));
for(const asset of manifest.files){
 if(!/^[a-zA-Z0-9_.-]+$/.test(asset.name)||!asset.url.startsWith('https://'))throw Error('资源清单路径错误');
 const destination=path.join(target,asset.name);
 const valid=data=>data.length===asset.bytes&&createHash('sha256').update(data).digest('hex')===asset.sha256;
 try{const data=await readFile(destination);if(!valid(data))throw Error('已有资源损坏：'+asset.name);console.log('复用 '+asset.name);continue;}catch(e){if(e.code!=='ENOENT')throw e;}
 const temporary=path.join(target,'.download-'+randomUUID());
 try{
  const proxy=process.env.CB_AVATAR_PROXY?['--proxy',process.env.CB_AVATAR_PROXY]:[];
  const result=spawnSync('curl',['-fL','--proto','=https','--max-filesize',String(asset.bytes),'--max-time','120',...proxy,'-o',temporary,asset.url],{stdio:'inherit'});
  if(result.status!==0)throw Error('下载失败：'+asset.name);
  if(!valid(await readFile(temporary)))throw Error('资源摘要不匹配：'+asset.name);
  await rename(temporary,destination);
 }finally{await unlink(temporary).catch(e=>{if(e.code!=='ENOENT')throw e;});}
}
await writeFile(path.join(target,'sources.json'),JSON.stringify(manifest,null,2));
