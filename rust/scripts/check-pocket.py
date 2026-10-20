#!/usr/bin/env python3
"""本文件的目的：在隔离目录检查安装、损坏拒绝、前端迁移与真实内存推理；绝不播放。
先运行 pocket-reference.py 和 pocket-download-test.py 准备对照资源。
"""
import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import wave
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/pocket-check'
BIN = ROOT / 'target/release/callbridge-pocket'
MANIFEST = ROOT / 'pocket/assets/package.json'
source = ROOT.parent.parent / 'pocket-tts-zh-4l-onnx'
manifest = json.loads(MANIFEST.read_text())

def run(*args, stdin=None, ok=True):
    result = subprocess.run([str(BIN), *map(str,args)], input=stdin, capture_output=True, timeout=100)
    if ok and result.returncode:
        raise RuntimeError(result.stderr.decode())
    return result

checks = []
def passed(name):
    checks.append(name)
    print('PASS', name, flush=True)

with tempfile.TemporaryDirectory(prefix='install-', dir=OUT) as tmp:
    base = Path(tmp)
    stage = base / '.pocket-download-test'
    stage.mkdir()
    target = base / 'installed'
    for a in manifest['downloads']:
        name = a['name']
        src = OUT / 'downloads' / name if name.endswith('.whl') else source / ('samples/short_unseen.wav' if name=='example.wav' else 'README.md' if name=='MODEL-README.md' else name)
        shutil.copy2(src,stage/name)
    # 任一下载损坏都不得出现 ready 或安装目标；失败保留诊断，不覆盖已有资源。
    original=(stage/'tokenizer.model').read_bytes()
    (stage/'tokenizer.model').write_bytes(b'x')
    assert run('finalize',stage,target,ok=False).returncode != 0
    assert not target.exists() and not (stage/'ready').exists()
    (stage/'tokenizer.model').write_bytes(original)
    passed('corrupt download never publishes')
    run('finalize',stage,target)
    run('verify',target)
    assert not stage.exists() and not list(target.glob('*.whl'))
    assert len(list(target.iterdir())) == len(manifest['files'])+1
    assert run('finalize',stage,target,ok=False).returncode != 0
    passed('atomic install, whitelist extraction, no overwrite')
    # 保存本轮已验证的安装供原生适配测试；只操作 build 内测试目录。
    native = OUT/'installed'
    if native.exists(): shutil.rmtree(native)
    shutil.copytree(target,native)
    front=(OUT/'frontend.json').read_bytes()
    actual=json.loads(run('frontend',target,stdin=front).stdout)
    assert actual==json.loads(front)
    passed(f'{len(actual)} normalized texts, pieces and token sequences equal Python')
    noise=json.loads(run('noise',target).stdout)
    reference=json.loads((OUT/'noise.json').read_bytes())
    max_noise=max(abs(struct.unpack('<f',struct.pack('<f',a))[0]-struct.unpack('<f',struct.pack('<f',b))[0]) for x,y in zip(noise,reference) for a,b in zip(x,y))
    assert max_noise<=1.2e-7
    passed('12800 random samples within float32 precision')
    pcm=run('infer',target,actual[1]['text']).stdout
    reference_pcm=(OUT/'reference.f32').read_bytes()
    assert pcm==reference_pcm
    passed('134400 decoded samples bit-identical to reference')
    with wave.open(str(OUT/'rust-reference.wav'),'wb') as w:
        w.setparams((1,2,24000,0,'NONE','not compressed'))
        floats=array.array('f',pcm)
        w.writeframes(b''.join(struct.pack('<h',max(-32768,min(32767,round(v*32768)))) for v in floats))
    results=[]
    for c in actual:
        data=run('speak',target,stdin=json.dumps({'text':c['text']},ensure_ascii=False).encode()).stdout
        assert data[:8]==b'CBPCM001'
        n=struct.unpack('<I',data[8:12])[0]
        assert len(data)==12+4*n and 0<n<=720000
        values=array.array('f',data[12:]);assert all(math.isfinite(x) and abs(x)<1 for x in values)
        results.append(dict(text_index=len(results),samples=n,seconds=n/24000,sha256=hashlib.sha256(data[12:]).hexdigest()))
    passed(f'{len(results)} full syntheses with normalization, silence retry and bounded PCM')
    sample=run('example',target).stdout
    assert sample[:8]==b'CBPCM001' and len(sample)>12
    assert run('speak',target,stdin=b'{"text":""}',ok=False).returncode!=0
    assert run('speak',target,stdin=b'x'*4097,ok=False).returncode!=0
    passed('example playback payload; empty and oversized input rejected')
    (target/'tokenizer.model').write_bytes(b'broken')
    broken=run('speak',target,stdin=b'{"text":"hello"}',ok=False)
    assert broken.returncode!=0 and not broken.stdout
    passed('tampered installation rejected before inference')
(OUT/'report.json').write_text(json.dumps(dict(checks=checks,installed_bytes=sum(x['bytes'] for x in manifest['files']),noise_max_abs=max_noise,reference_pcm_equal=True,synthesis=results),indent=2)+'\n')
print(f'{len(checks)} checks passed')
