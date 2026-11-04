#!/usr/bin/env python3
"""本文件的目的：检查实际发布归档、清单和使用文档，不依赖开发目录补齐缺文件。
只读归档和源码，不解压不可信路径、不运行 App、不访问用户设置或媒体设备。
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import tarfile
from urllib.parse import unquote, urlsplit
import zipfile
import posixpath
import stat
import subprocess
from update_release import verify_feed

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_files', ROOT / 'scripts/release-files.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def check_docs():
    names = set(policy.files())
    issues = []
    forbidden = re.compile(r'本地测试|本地验证|本地验收|验证记录|验收记录|local tests?|local results', re.I)
    for name in sorted(names):
        if not name.endswith('.md'):
            continue
        content = (ROOT / name).read_text()
        if forbidden.search(content):
            issues.append(name + ': contains internal check wording')
        # 使用说明的相对链接必须随源码一起提供；外部网址交由用户在联网时打开。
        for target in re.findall(r'!?\[[^\]]*\]\(([^\s)]+)\)', content):
            url = urlsplit(target.strip('<>'))
            if url.scheme or not url.path:
                continue
            dest = ((ROOT / name).parent / unquote(url.path)).resolve()
            try:
                rel = dest.relative_to(ROOT).as_posix()
            except ValueError:
                issues.append(name + ': link leaves source tree')
                continue
            if rel not in names and not any(n.startswith(rel.rstrip('/') + '/') for n in names):
                issues.append(name + ': missing packaged link ' + rel)
    if issues:
        raise ValueError('\n'.join(issues))
    return len([n for n in names if n.endswith('.md')])

def verify_payload(data, item):
    assert len(data) == item['bytes'], item['path'] + ': size mismatch'
    assert digest(data) == item['sha256'], item['path'] + ': digest mismatch'

def verify_archive_paths(names):
    assert len(names) == len(set(names)), 'Duplicate archive paths'
    for name in names:
        path = PurePosixPath(name)
        assert not path.is_absolute() and '..' not in path.parts and '\\' not in name, 'Unsafe archive path'
        assert not any(p in {'__pycache__', 'node_modules', '.git', '.env'} for p in path.parts), name
        assert not name.endswith(('.pyc', '.p12', '.mobileprovision')), name

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--docs-only', action='store_true')
    parser.add_argument('--source-only', action='store_true')
    args = parser.parse_args()
    docs = check_docs()
    if args.docs_only:
        print(json.dumps({'passed': True, 'public_documents': docs}))
        return
    info = plistlib.loads((ROOT / 'rust/native/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    folder = ROOT / 'rust/build/releases' / version
    sums = {}
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        checksum, name = line.split('  ', 1)
        assert Path(name).name == name and name not in sums
        assert digest((folder / name).read_bytes()) == checksum, name + ': checksum mismatch'
        sums[name] = checksum
    source_name = f'CallBridge-{version}-source.tar.gz'
    assert source_name in sums and 'SOURCE_MANIFEST.json' in sums and 'UPLOAD_FILES.txt' in sums
    if f'CallBridge-{version}-windows-x64.zip' in sums:
        subprocess.run(['python3', str(ROOT / 'scripts/check-windows.py')], check=True)
    source = json.loads((folder / 'SOURCE_MANIFEST.json').read_text())
    assert (source['version'], source['build']) == (version, build)
    inventory = {item['path']: item for item in source['files']}
    assert len(inventory) == len(source['files'])
    assert set(inventory) == set(policy.files()), 'Source inventory is stale'
    # 源码包必须能找到 Windows 入口和云服务说明，不能依赖被忽略的维护者文档。
    cloud_guides = ['README', 'api', 'decart', 'liveavatar', 'tavus', 'fashn', 'zego', 'xmov', 'heygen', 'synthesia']
    source_required = {'CB.ps1', 'CBT.ps1', 'rust/scripts/build-windows.ps1',
                       'rust/windows/CallBridge.Windows/CallBridge.Windows.csproj'}
    source_required.update('rust/avatar/cloud-guides/' + name + '.md' for name in cloud_guides)
    assert source_required <= inventory.keys(), 'Missing platform source or bundled cloud documentation'
    assert (folder / 'UPLOAD_FILES.txt').read_text().splitlines() == sorted(inventory)
    prefix = f'CallBridge-{version}/'
    with tarfile.open(folder / source_name) as archive:
        names = archive.getnames()
        verify_archive_paths(names)
        assert set(names) == {prefix + name for name in inventory} | {prefix + 'SOURCE_MANIFEST.json'}
        assert all(member.isfile() for member in archive.getmembers()), 'Source must contain regular files only'
        assert archive.extractfile(prefix + 'SOURCE_MANIFEST.json').read() == (folder / 'SOURCE_MANIFEST.json').read_bytes()
        for name, item in inventory.items():
            verify_payload(archive.extractfile(prefix + name).read(), item)
            verify_payload((ROOT / name).read_bytes(), item)
    if not args.source_only:
        zip_name = f'CallBridge-{version}-macos-arm64.zip'
        assert zip_name in sums and 'APP_MANIFEST.json' in sums and 'appcast.xml' in sums
        verify_feed(folder / 'appcast.xml', folder / zip_name, info)
        manifest = json.loads((folder / 'APP_MANIFEST.json').read_text())
        assert (manifest['version'], manifest['build']) == (version, build)
        entries = {item['path']: item for item in manifest['files']}
        assert len(entries) == len(manifest['files'])
        required = {'Contents/MacOS/CallBridge', 'Contents/MacOS/callbridge-pocket', 'Contents/MacOS/node',
                    'Contents/Resources/GETTING_STARTED.md', 'Contents/Resources/Licenses/LICENSE',
                    'Contents/Resources/Licenses/THIRD_PARTY_LICENSES.txt', 'Contents/Resources/Licenses/NODE-LICENSE',
                    'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
                    'Contents/Resources/Licenses/SPARKLE-LICENSE'}
        assert required <= entries.keys(), 'Missing App runtime or licenses'
        cloud_required = {'Contents/Resources/Cloud/providers.json', 'Contents/Resources/Cloud/api.md',
                          'Contents/Resources/Cloud/README.md',
                          'Contents/Resources/Avatar/cloud/native-host.mjs',
                          'Contents/Resources/Avatar/cloud/providers.mjs'}
        cloud_required.update('Contents/Resources/Cloud/' + name + '.md' for name in cloud_guides[2:])
        assert cloud_required <= entries.keys(), 'Missing cloud host or provider guides'
        with zipfile.ZipFile(folder / zip_name) as archive:
            assert archive.testzip() is None, 'ZIP CRC failure'
            files = [item.filename for item in archive.infolist() if not item.is_dir()]
            verify_archive_paths(files)
            assert set(files) == {'CallBridge.app/' + name for name in entries}
            for name, item in entries.items():
                path = 'CallBridge.app/' + name
                if 'symlink' in item:
                    target = item['symlink']
                    assert stat.S_ISLNK(archive.getinfo(path).external_attr >> 16), path
                    assert archive.read(path).decode() == target
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
                    assert not target.startswith('/') and resolved.startswith('CallBridge.app/Contents/'), path
                else:
                    verify_payload(archive.read(path), item)
            bundled = plistlib.loads(archive.read('CallBridge.app/Contents/Info.plist'))
            assert (bundled['CFBundleShortVersionString'], bundled['CFBundleVersion']) == (version, build)
            assert bundled['CBEnableUpdates'] is True
            for key in ('SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate',
                        'SUScheduledCheckInterval', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed',
                        'SUSignedFeedFailureExpirationInterval', 'SUEnableSystemProfiling'):
                assert bundled[key] == info[key], key
            assert json.loads(archive.read('CallBridge.app/Contents/Resources/Avatar/runtime.json')) == {'schema': 1, 'node_minimum_major': 22}
            assert archive.read('CallBridge.app/Contents/Resources/GETTING_STARTED.md') == (ROOT / 'GETTING_STARTED.md').read_bytes()
    print(json.dumps({'passed': True, 'version': version, 'build': build, 'source_files': len(inventory),
                      'public_documents': docs, 'checksummed_files': len(sums), 'media_io': False}))

if __name__ == '__main__':
    main()
