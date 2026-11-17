#!/usr/bin/env python3
"""对真实图集和恶意变体运行宿主校验，不安装到用户目录、不访问设备。"""
import hashlib,json,struct,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'build/frame-avatar/umbrella-gentleman/plugin'
worker=ROOT/'target/release/callbridge-pocket'
original=(source/'character.cbframe').read_bytes()
manifest=json.loads((source/'manifest.json').read_text())
length=struct.unpack('<I',original[8:12])[0]
header=original[12:12+length]
png=original[12+length:]
def check(data,expected):
 with tempfile.TemporaryDirectory(prefix='cb-frame-') as tmp:
  root=Path(tmp).resolve();(root/'character.cbframe').write_bytes(data)
  m=dict(manifest);m['files']=[dict(path='character.cbframe',bytes=len(data),sha256=hashlib.sha256(data).hexdigest())]
  (root/'manifest.json').write_text(json.dumps(m))
  result=subprocess.run([str(worker),'plugin-check',str(root)],capture_output=True,text=True,timeout=20)
  assert (result.returncode==0)==expected,result.stderr
def payload(h,p=png):return b'CBFA'+struct.pack('<II',1,len(h))+h+p
check(original,True)
check(original[:44],False)
check(payload(header,png[:50]),False)
check(payload(header[:-1]+b',"url":"https://example.com"}'),False)
check(payload(header[:-1]+b',"width":1254}'),False)
check(payload(header.replace(b'1254',b'4097')),False)
check(b'CBFA'+struct.pack('<II',1,0xffffffff)+png,False)
print('PASS: real atlas and 6 malformed variants; no install/device IO')
