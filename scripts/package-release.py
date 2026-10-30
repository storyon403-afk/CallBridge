#!/usr/bin/env python3
"""本文件的目的：生成源码、App 和完整性清单；不提交、不推送、不公证、不安装设备。"""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_files',ROOT/'scripts/release-files.py')
policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
args=argparse.ArgumentParser();args.add_argument('--source-only',action='store_true');opts=args.parse_args()
info=plistlib.loads((ROOT/'rust/native/Info.plist').read_bytes());version=info['CFBundleShortVersionString']
OUT=ROOT/'rust/build/releases'/version;OUT.mkdir(parents=True,exist_ok=True)
files=policy.files();required=['LICENSE','NOTICE','LICENSING.md','SECURITY.md','THIRD_PARTY_NOTICES.md','GETTING_STARTED.md','release/NOTES.md','rust/native/plugin_store.m','rust/pocket/src/plugins.rs']
for name in required:
    if name not in files:raise SystemExit('Missing release source: '+name)
subprocess.run(['python3',str(ROOT/'scripts/check-source-security.py')],check=True)
inventory=[{'path':n,'bytes':(ROOT/n).stat().st_size,'sha256':hashlib.sha256((ROOT/n).read_bytes()).hexdigest()} for n in files]
manifest=json.dumps({'version':version,'build':info['CFBundleVersion'],'files':inventory},ensure_ascii=False,indent=2).encode()+b'\n'
source=OUT/f'CallBridge-{version}-source.tar.gz';prefix=f'CallBridge-{version}'
# 时间戳、uid/gid 固定；不把当前登录用户名或本机路径写入源码归档。
with source.open('wb') as f,gzip.GzipFile(fileobj=f,mode='wb',mtime=0,filename='') as gz,tarfile.open(fileobj=gz,mode='w') as tar:
    for name,data in [(n,(ROOT/n).read_bytes()) for n in files]+[('SOURCE_MANIFEST.json',manifest)]:
        entry=tarfile.TarInfo(prefix+'/'+name);entry.size=len(data);entry.mtime=0;entry.mode=0o755 if name in files and (ROOT/name).stat().st_mode&0o111 else 0o644
        tar.addfile(entry,io.BytesIO(data))
(OUT/'SOURCE_MANIFEST.json').write_bytes(manifest)
(OUT/'UPLOAD_FILES.txt').write_text('\n'.join(files)+'\n')
artifacts=[source,OUT/'SOURCE_MANIFEST.json',OUT/'UPLOAD_FILES.txt']
if not opts.source_only:
    runtime=ROOT/'rust/build/release-runtime';provenance=json.loads((runtime/'provenance.json').read_text());lock=json.loads((ROOT/'release/node-runtime.json').read_text())
    if provenance['sha256']!=lock['sha256'] or hashlib.sha256((runtime/'node').read_bytes()).hexdigest()!=provenance['binary_sha256']:raise SystemExit('Prepared runtime checksum mismatch')
    subprocess.run(['python3',str(ROOT/'scripts/collect-licenses.py')],check=True)
    app=ROOT/'rust/build/app/CallBridge.app';subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    built=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if any(built[key]!=info[key] for key in ['CFBundleShortVersionString','CFBundleVersion']):raise SystemExit('Rebuild App before packaging')
    with tempfile.TemporaryDirectory(prefix='release-stage-',dir=ROOT/'rust/build') as temp:
        stage=Path(temp)/'CallBridge.app';shutil.copytree(app,stage)
        node=stage/'Contents/MacOS/node';shutil.copy2(runtime/'node',node)
        licenses=stage/'Contents/Resources/Licenses';licenses.mkdir(exist_ok=True)
        for name in ['LICENSE','NOTICE','LICENSING.md','THIRD_PARTY_NOTICES.md']:shutil.copy2(ROOT/name,licenses/name)
        for p in (ROOT/'rust/build/licenses').iterdir():shutil.copy2(p,licenses/p.name)
        shutil.copy2(runtime/'NODE-LICENSE',licenses/'NODE-LICENSE')
        shutil.copy2(runtime/'provenance.json',licenses/'node-runtime.json')
        shutil.copy2(ROOT/'GETTING_STARTED.md',stage/'Contents/Resources/GETTING_STARTED.md')
        subprocess.run(['codesign','--force','--sign','-',str(node)],check=True)
        subprocess.run(['codesign','--force','--sign','-',str(stage)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
        # 发行配置禁止开发机目录；固定资源无个人插件、录音和偏好。
        config=json.loads((stage/'Contents/Resources/Avatar/runtime.json').read_text())
        if config!={'schema':1,'node_minimum_major':22}:raise SystemExit('Nonportable runtime config')
        if list(stage.rglob('settings-v1.plist')) or list(stage.rglob('voice.safetensors')):raise SystemExit('Private resource in App')
        binary=OUT/f'CallBridge-{version}-macos-arm64.zip'
        subprocess.run(['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(stage),str(binary)],check=True);artifacts.append(binary)
        (OUT/'APP_MANIFEST.json').write_text(json.dumps({'version':version,'build':info['CFBundleVersion'],'signature':'ad-hoc','notarized':False,'files':[{'path':p.relative_to(stage).as_posix(),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(stage.rglob('*')) if p.is_file()]},indent=2)+'\n')
        artifacts.append(OUT/'APP_MANIFEST.json')
    shutil.copy2(ROOT/'GETTING_STARTED.md',OUT/'GETTING_STARTED.md')
    shutil.copy2(ROOT/'SECURITY.md',OUT/'SECURITY.md')
    shutil.copy2(ROOT/'release/NOTES.md',OUT/'RELEASE_NOTES.md')
    artifacts.extend(OUT/name for name in ['GETTING_STARTED.md','SECURITY.md','RELEASE_NOTES.md'])
(OUT/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in artifacts))
print(json.dumps({'version':version,'source_files':len(files),'artifacts':[str(p) for p in artifacts],'published':False}))
