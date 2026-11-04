#!/usr/bin/env python3
"""组装独立 Windows 测试包；只复用已构建的程序和锁定运行时，不运行 GUI 或媒体。"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'rust/build/windows'
LOCK = ROOT / 'release/windows-runtime.json'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def extract(archive, destination):
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            target = (destination / item.filename).resolve()
            if not target.is_relative_to(destination.resolve()) or '\\' in item.filename:
                raise ValueError('Unsafe archive path: ' + item.filename)
        bundle.extractall(destination)

def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--llvm-mingw', type=Path, required=True)
    parser.add_argument('--restore', action='store_true', help='Download missing locked runtime archives')
    parser.add_argument('--revision', default='', help='Optional local test revision, e.g. ui1')
    args = parser.parse_args()
    if args.revision and not re.fullmatch(r'[a-z0-9]+', args.revision):
        parser.error('revision must contain only lowercase letters and digits')
    mingw = args.llvm_mingw.resolve()
    lock = json.loads(LOCK.read_text())
    downloads = BUILD / 'downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    for entry in lock['files']:
        target = downloads / entry['name']
        if not target.exists() and args.restore:
            partial = target.with_suffix(target.suffix + '.partial')
            subprocess.run(['curl', '-fLsS', '--retry', '2', '--max-time', '300', entry['url'], '-o', str(partial)], check=True)
            if sha(partial) != entry['sha256']:
                raise ValueError('Download checksum mismatch: ' + entry['name'])
            partial.replace(target)
        if not target.exists() or sha(target) != entry['sha256']:
            raise ValueError('Missing or changed runtime: ' + entry['name'])
    info = plistlib.loads((ROOT / 'rust/native/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    name = f'CallBridge-{version}-windows-x64' + ('-' + args.revision if args.revision else '')
    output = ROOT / 'rust/build/releases' / version
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='portable-', dir=BUILD) as temp:
        stage = Path(temp) / name
        shutil.copytree(BUILD / 'cross-compiled', stage, ignore=shutil.ignore_patterns('*.pdb'))
        # 检查程序共用应用的 .NET 核心；桌面框架会替换少数转发程序集，不能反向覆盖。
        app_config = json.loads((stage / 'CallBridge.runtimeconfig.json').read_text())
        check_config = json.loads((BUILD / 'portable-checks/CallBridge.CoreChecks.runtimeconfig.json').read_text())
        app_frameworks = app_config['runtimeOptions']['includedFrameworks']
        assert all(f in app_frameworks for f in check_config['runtimeOptions']['includedFrameworks'])
        for source in (BUILD / 'portable-checks').rglob('*'):
            if not source.is_file() or source.suffix == '.pdb':
                continue
            dest = stage / source.relative_to(BUILD / 'portable-checks')
            if source.name.startswith('CallBridge.CoreChecks.'):
                copy(source, dest)
            elif dest.exists() and source.name == 'NAudio.Core.dll':
                if sha(source) != sha(dest):
                    raise ValueError('Conflicting .NET runtime: ' + dest.name)
            elif not dest.exists():
                copy(source, dest)
        core = ROOT / 'rust/target/x86_64-pc-windows-gnullvm/release/callbridge_abi_probe.dll'
        unwind = mingw / 'x86_64-w64-mingw32/bin/libunwind.dll'
        for folder in [stage, stage / 'camera']:
            copy(core, folder / core.name)
            copy(unwind, folder / unwind.name)
        copy(BUILD / 'callbridge-camera-sender.exe', stage / 'camera/callbridge-camera-sender.exe')
        for source in (ROOT / 'rust/windows/camera').iterdir():
            if source.is_file():
                copy(source, stage / 'camera' / source.name)
        # 诊断复用原检查脚本，只替换包内模块位置；始终使用 memoryOnly。
        bridge = stage / 'camera/check_bridge.mjs'
        bridge.write_text(bridge.read_text().replace('../../avatar/scripts/camera-bridge.mjs', '../avatar-host/camera-bridge.mjs'))
        python = stage / 'camera/python'
        extract(downloads / 'python.zip', python)
        (python / 'python313._pth').write_text('python313.zip\n.\nLib/site-packages\nimport site\n')
        site = python / 'Lib/site-packages'
        for entry in lock['files']:
            if entry['name'].endswith('.whl'):
                extract(downloads / entry['name'], site)
        # NumPy 的官方 wheel 已附带 MSVC C++ 运行库；pyvirtualcam 使用原始 DLL 名称。
        # 将同一运行库放到 Python 程序旁，避免要求用户额外安装全局 VC++ 组件。
        cpp_runtime = list((site / 'numpy.libs').glob('msvcp140-*.dll'))
        assert len(cpp_runtime) == 1
        copy(cpp_runtime[0], python / 'MSVCP140.dll')
        node_temp = Path(temp) / 'node'
        extract(downloads / 'node.zip', node_temp)
        node = node_temp / f"node-v{lock['node']}-win-x64"
        copy(node / 'node.exe', stage / 'runtime/node.exe')
        copy(node / 'LICENSE', stage / 'licenses/NODE-LICENSE')
        shutil.copytree(ROOT / 'rust/build/avatar', stage / 'avatar')
        copy(ROOT / 'rust/avatar/preview.jpg', stage / 'avatar/preview.jpg')
        for filename in ['server.mjs', 'camera-bridge.mjs']:
            copy(ROOT / 'rust/avatar/scripts' / filename, stage / 'avatar-host' / filename)
        shutil.copytree(ROOT / 'rust/avatar/scripts/cloud', stage / 'avatar-host/cloud')
        shutil.copytree(ROOT / 'rust/avatar/cloud-guides', stage / 'cloud-guides')
        copy(ROOT / 'LICENSE', stage / 'LICENSE')
        copy(ROOT / 'NOTICE', stage / 'NOTICE')
        copy(ROOT / 'THIRD_PARTY_NOTICES.md', stage / 'licenses/THIRD_PARTY_NOTICES.md')
        copy(ROOT / 'rust/windows/THIRD_PARTY.md', stage / 'licenses/WINDOWS-THIRD-PARTY.md')
        copy(ROOT / 'rust/windows/PORTABLE.md', stage / 'README.md')
        copy(ROOT / 'rust/windows/UI-ACCEPTANCE.md', stage / 'UI-ACCEPTANCE.md')
        copy(ROOT / 'rust/windows/Test-Windows.cmd', stage / 'Test-Windows.cmd')
        copy(LOCK, stage / 'licenses/windows-runtime.json')
        copy(mingw / 'LICENSE.TXT', stage / 'licenses/LLVM-MINGW-LICENSE.TXT')
        for source in (mingw / 'share').rglob('*'):
            if source.is_file() and ('license' in source.name.lower() or 'copying' in source.name.lower()):
                copy(source, stage / 'licenses/llvm-mingw' / source.relative_to(mingw / 'share'))
        # 文件清单在压缩前生成，使用相对路径，不写入开发机目录或账号信息。
        files = [{'path':p.relative_to(stage).as_posix(), 'bytes':p.stat().st_size, 'sha256':sha(p)}
                 for p in sorted(stage.rglob('*')) if p.is_file()]
        manifest = {'version':version, 'build':info['CFBundleVersion'], 'platform':'windows-x64',
                    'revision':args.revision, 'windows_execution_verified':False, 'files':files}
        (stage / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
        archive = output / (name + '.zip')
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
            for p in sorted(stage.rglob('*')):
                if p.is_file():
                    bundle.write(p, name + '/' + p.relative_to(stage).as_posix())
        with zipfile.ZipFile(archive) as bundle:
            assert bundle.testzip() is None
            for entry in files:
                data = bundle.read(name + '/' + entry['path'])
                assert len(data) == entry['bytes'] and hashlib.sha256(data).hexdigest() == entry['sha256']
        sums = output / ('WINDOWS-' + args.revision + '-SHA256SUMS' if args.revision else 'WINDOWS-SHA256SUMS')
        sums.write_text(sha(archive) + '  ' + archive.name + '\n')
        print(json.dumps({'archive':str(archive), 'bytes':archive.stat().st_size, 'files':len(files), 'verified':True}))

if __name__ == '__main__':
    main()
