#!/usr/bin/env python3
"""将已审阅的图集封装为自包含帧角色；不下载素材，不生成图像，不安装插件。"""
import hashlib
import json
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'plugins/experimental/umbrella-gentleman/atlas-v1.png'
OUT = ROOT / 'rust/build/frame-avatar/umbrella-gentleman'

def main():
    png = SOURCE.read_bytes()
    if png[:8] != b'\x89PNG\r\n\x1a\n' or png[24:26] != bytes([8, 6]):
        raise ValueError('需要 8-bit RGBA PNG')
    width, height = struct.unpack('>II', png[16:24])
    if not (5 <= width <= 4096 and 5 <= height <= 4096):
        raise ValueError('图集尺寸超限')
    layout = dict(width=width, height=height, columns=5, rows=5,
                  yaws=[-.5, -.25, 0, .25, .5],
                  expressions=['neutral', 'blink', 'talk', 'smile', 'frown'])
    header = json.dumps(layout, separators=(',', ':')).encode()
    data = b'CBFA' + struct.pack('<II', 1, len(header)) + header + png
    if len(data) > 16 * 1024 * 1024:
        raise ValueError('帧角色超过 16 MiB')
    manifest = dict(schema=1, api=1, id='local.callbridge.umbrella-gentleman', version='0.1.0',
                    name='黑伞绅士 · 2D 帧形象（实验版）', kind='avatar', core_min='0.13.11',
                    core_max='0.14.0', platforms=['macos-arm64'],
                    dependencies=[dict(id='avatar-holistic-v1', version='1.0.0')], permissions=[],
                    license='LicenseRef-Source-Character-Rights-Unverified',
                    author='Video attribution: antrofrog; AI-assisted frame adaptation',
                    entry='character.cbframe', files=[dict(path='character.cbframe', bytes=len(data),
                    sha256=hashlib.sha256(data).hexdigest())])
    directory = OUT / 'plugin'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'character.cbframe').write_bytes(data)
    (directory / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    archive = OUT / 'umbrella-gentleman-0.1.0.cbplugin'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in ['manifest.json', 'character.cbframe']:
            z.write(directory / name, name)
    print(json.dumps(dict(archive=str(archive), bytes=archive.stat().st_size,
                         frames=25, atlas=[width,height], sha256=manifest['files'][0]['sha256'])))

if __name__ == '__main__':
    main()
