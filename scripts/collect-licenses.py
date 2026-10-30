#!/usr/bin/env python3
"""本文件的目的：从锁定且已下载的依赖生成许可证与清单；不把本机 registry 路径写入发行产物。"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'rust/build/licenses';OUT.mkdir(parents=True,exist_ok=True)
packages={};missing=[];texts=[]
fallbacks=json.loads((ROOT/'release/licenses/sources.json').read_text())
for manifest in ['rust/Cargo.toml','rust/pocket/Cargo.toml']:
    metadata=json.loads(subprocess.check_output(['cargo','metadata','--offline','--locked','--format-version','1','--manifest-path',str(ROOT/manifest)]))
    for p in metadata['packages']:
        if not p.get('source'):continue
        key=(p['name'],p['version']);folder=Path(p['manifest_path']).parent
        if key in packages:continue
        names=[]
        for f in sorted(folder.iterdir()):
            if f.is_file() and f.name.upper().startswith(('LICENSE','LICENCE','COPYING','NOTICE','COPYRIGHT','AUTHORS')):names.append(f)
            elif f.is_dir() and f.name.lower() in {'licenses','license'}:names.extend(p for p in f.rglob('*') if p.is_file())
        if p.get('license_file'):
            f=folder/p['license_file']
            if f.is_file():names.append(f)
        names=sorted(set(names))
        fallback=fallbacks.get('/'.join(key))
        if not names and fallback:
            folder=ROOT/'release/licenses';f=folder/fallback['file']
            if hashlib.sha256(f.read_bytes()).hexdigest()!=fallback['sha256']:raise SystemExit('License checksum mismatch: '+str(key))
            names=[f]
        if not names:missing.append('/'.join(key));continue
        entry={'name':key[0],'version':key[1],'license':p.get('license'),'repository':p.get('repository'),'source':p['source'],'license_files':[]}
        if fallback:entry['license_origin']=fallback['url']
        for f in names:
            value=f.read_text(errors='replace');entry['license_files'].append({'path':f.relative_to(folder).as_posix(),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
            texts.append('\n===== '+key[0]+' '+key[1]+' / '+f.relative_to(folder).as_posix()+' =====\n'+value)
        packages[key]=entry
# 收集锁定的全部非开发 npm 依赖，包括 three-vrm 的子库；不只保留顶层包的声明。
npm=[]
for name,p in json.loads((ROOT/'rust/avatar/package-lock.json').read_text())['packages'].items():
    if not name or p.get('dev'):continue
    folder=ROOT/'rust/avatar'/name
    names=sorted(f for f in folder.iterdir() if f.is_file() and f.name.upper().startswith(('LICENSE','LICENCE','COPYING','NOTICE')))
    key=name.removeprefix('node_modules/')+'/'+p['version'];fallback=fallbacks.get(key)
    if not names and fallback:
        folder=ROOT/'release/licenses';f=folder/fallback['file']
        if hashlib.sha256(f.read_bytes()).hexdigest()!=fallback['sha256']:raise SystemExit('License checksum mismatch: '+key)
        names=[f]
    if not names:missing.append(key);continue
    entry={'name':name.removeprefix('node_modules/'),'version':p['version'],'license':p.get('license'),'license_files':[]}
    if fallback:entry['license_origin']=fallback['url']
    for f in names:
        entry['license_files'].append({'path':f.relative_to(folder).as_posix(),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
        texts.append('\n===== '+key+' / '+f.name+' =====\n'+f.read_text())
    npm.append(entry)
for p in [ROOT/'rust/pocket/POCKET-TTS-LICENSE',ROOT/'rust/avatar/THIRD_PARTY.txt']:
    texts.append('\n===== '+p.name+' =====\n'+p.read_text())
(OUT/'DEPENDENCIES.json').write_text(json.dumps({'cargo':list(packages.values()),'npm':npm,'missing_license_texts':missing},indent=2)+'\n')
(OUT/'THIRD_PARTY_LICENSES.txt').write_text('\n'.join(texts))
print(json.dumps({'cargo_packages':len(packages),'npm_packages':len(npm),'missing':missing}))
if missing:sys.exit(1)
