"""本文件的目的：打包轻量形象宿主，插件大文件留在开发缓存，不随主 App 分发。
只清理本次构建生成的 Avatar/site 目录；完整开发资源不删除，供显式安装复用。
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[2]
source = root / 'build/avatar'
destination = Path(sys.argv[1]).resolve() / 'Contents/Resources/Avatar'
site = destination / 'site'
manifest = json.loads((root / 'avatar/plugin.lock.json').read_text())
for entry in manifest['files']:
    data = (source / entry['path']).read_bytes()
    if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise ValueError('插件缓存摘要不一致：' + entry['path'])
destination.mkdir(parents=True, exist_ok=True)
if site.exists():
    shutil.rmtree(site)
shutil.copytree(source, site, ignore=lambda directory, names: {'model', 'vendor'} if Path(directory) == source else set())
shutil.copyfile(root / 'avatar/plugin.lock.json', destination / 'plugin.lock.json')
# 目录预览随轻量宿主提供；无需安装 47.6 MB 插件即可查看原角色效果。
shutil.copyfile(root / 'avatar/preview.jpg', destination / 'preview.jpg')
for name in ['server.mjs', 'camera-bridge.mjs']:
    shutil.copyfile(root / 'avatar/scripts' / name, destination / name)
(destination / 'runtime.json').write_text(json.dumps({'node': shutil.which('node'), 'avatar_cache': str(source)}))
print('形象宿主已打包；可选插件：', sum(e['bytes'] for e in manifest['files']), 'bytes')
