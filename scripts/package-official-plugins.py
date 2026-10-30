#!/usr/bin/env python3
"""目的：可复现地生成官方样例包及下载清单；只写本地，不上传、不安装、不读取私人素材。"""
import argparse
import hashlib
import io
import json
import math
import shutil
from pathlib import Path
import struct
import wave
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'plugins/official/catalog.json'
OUTPUT = ROOT / 'build/official-plugins/plugins-v1'
BASE = 'https://github.com/storyon403-afk/CallBridge/releases/download/plugins-v1/'


def png():
    # 原创几何渐变，无第三方图像、字体或照片；PNG 直接编码以保持重建字节一致。
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    rows = bytearray()
    for y in range(360):
        rows.append(0)
        for x in range(640):
            rows.extend((24 + x * 28 // 640, 37 + y * 35 // 360, 53 + (x + y) * 35 // 1000))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 640, 360, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b'')


def ambience():
    # 周期整频、低电平的原创合成环境音；不采集麦克风，不读取录音。
    out = io.BytesIO()
    with wave.open(out, 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b''.join(struct.pack('<h', round(550 * math.sin(2 * math.pi * 110 * i / 16000) + 220 * math.sin(2 * math.pi * 165 * i / 16000))) for i in range(64000)))
    return out.getvalue()


def packages():
    return [
        ('light-denoise', 'audio-denoise', 'settings.json', (ROOT / 'plugins/official/examples/light-denoise/settings.json').read_bytes(), {'zh-Hans':'轻度降噪样例','en':'Light denoise sample','ja':'軽いノイズ除去サンプル'}, []),
        ('soft-room', 'audio-background', 'background.wav', ambience(), {'zh-Hans':'柔和环境音样例','en':'Soft ambience sample','ja':'穏やかな環境音サンプル'}, []),
        ('dusk', 'background-image', 'background.png', png(), {'zh-Hans':'暮色背景样例','en':'Dusk background sample','ja':'夕暮れ背景サンプル'}, [{'id':'avatar-holistic-v1','version':'1.0.0'}]),
    ]


def build():
    result = []
    for slug, kind, entry, data, names, dependencies in packages():
        manifest = dict(schema=1, api=1, id='org.callbridge.'+slug, version='1.0.0', name=names['zh-Hans'], kind=kind,
                        core_min='0.13.11', core_max='0.14.0', platforms=['any'], dependencies=dependencies, permissions=[],
                        license='PolyForm-Noncommercial-1.0.0', author='CallBridge', entry=entry,
                        files=[dict(path=entry, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())])
        encoded = (json.dumps(manifest, ensure_ascii=False, indent=2)+'\n').encode()
        output = io.BytesIO()
        # 固定时间戳及权限；不引入操作系统用户名、绝对路径或 Finder 隐藏文件。
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, payload in [('manifest.json', encoded), (entry, data)]:
                info=zipfile.ZipInfo(name, (2026,1,1,0,0,0));info.external_attr=0o100644<<16
                archive.writestr(info,payload)
        payload=output.getvalue();filename=slug+'-1.0.0.cbplugin'
        record=dict(id=manifest['id'],version=manifest['version'],kind=kind,names=names,bytes=len(payload),
                    sha256=hashlib.sha256(payload).hexdigest(),url=BASE+filename,published=False,dependencies=dependencies)
        result.append((record,payload,encoded))
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--verify-published',action='store_true');args=parser.parse_args()
    previous=json.loads(CATALOG.read_text()) if CATALOG.exists() else {'plugins':[]}
    published={p['id']:p.get('published',False) for p in previous['plugins']}
    built=build();catalog={'schema':1,'plugins':[]}
    if args.verify_published:
        # 发布后的只读验证：所有附件存在且字节相符后才把目录标为可下载。
        import urllib.request
        for record,payload,_ in built:
            with urllib.request.urlopen(record['url'],timeout=60) as response:
                if not response.url.startswith('https://'):raise SystemExit('HTTPS required')
                remote=response.read(len(payload)+1)
            if remote!=payload:raise SystemExit('Published asset differs: '+record['id'])
        published={record['id']:True for record,_,_ in built}
    for record,payload,manifest in built:
        record['published']=published.get(record['id'],False)
        old=next((p for p in previous['plugins'] if p['id']==record['id']),None)
        if old and old.get('published') and any(old.get(k)!=v for k,v in record.items() if k!='published'):
            raise SystemExit('Do not replace a published version; create a new version and tag')
        catalog['plugins'].append(record)
        if not args.check:
            OUTPUT.mkdir(parents=True,exist_ok=True);(OUTPUT/record['url'].rsplit('/',1)[1]).write_bytes(payload)
            if record['kind']=='audio-denoise':(ROOT/'plugins/official/examples/light-denoise/manifest.json').write_bytes(manifest)
    if args.check:
        if catalog!=previous:raise SystemExit('Catalog differs from reproducible samples; regenerate it')
    else:
        CATALOG.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
        (OUTPUT/'SHA256SUMS').write_text(''.join(p['sha256']+'  '+p['url'].rsplit('/',1)[1]+'\n' for p in catalog['plugins']))
        shutil.copy2(ROOT/'LICENSE',OUTPUT/'LICENSE')
    print(json.dumps({'plugins':len(built),'payload_bytes':sum(len(b) for _,b,_ in built),'published':False,'output':str(OUTPUT)}))

if __name__=='__main__':main()
