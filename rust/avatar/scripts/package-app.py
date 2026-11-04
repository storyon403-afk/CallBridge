"""本文件的目的：打包轻量形象宿主，插件大文件留在开发缓存，不随主 App 分发。
只清理本次构建生成的 Avatar/site 目录；完整开发资源不删除，供显式安装复用。
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import subprocess

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
# 云端长期凭据由宿主会话注入，包内只带协议适配代码，不带账号或配置副本。
shutil.copytree(root / 'avatar/scripts/cloud', destination / 'cloud', dirs_exist_ok=True)
# 发行包不记录开发者 HOME、Node 安装路径或缓存；可选运行时只放在固定包内位置。
(destination / 'runtime.json').write_text(json.dumps({'schema': 1, 'node_minimum_major': 22}))
print('形象宿主已打包；可选插件：', sum(e['bytes'] for e in manifest['files']), 'bytes')

# 厂商目录由同一适配注册表生成；说明随包离线可读，不复制密钥或用户设置。
cloud_docs = destination.parent / 'Cloud'
cloud_docs.mkdir(exist_ok=True)
registry = (root / 'avatar/scripts/cloud/providers.mjs').as_uri()
metadata = subprocess.check_output(['node', '--input-type=module', '-e',
    'import {PROVIDERS} from ' + json.dumps(registry) + ';process.stdout.write(JSON.stringify(PROVIDERS));'])
(cloud_docs / 'providers.json').write_bytes(metadata)
for provider in json.loads(metadata):
    shutil.copyfile(root / 'avatar/cloud-guides' / (provider['guide'] + '.md'), cloud_docs / (provider['guide'] + '.md'))
for name in ['api.md', 'README.md']:
    shutil.copyfile(root / 'avatar/cloud-guides' / name, cloud_docs / name)
