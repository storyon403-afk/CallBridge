#!/usr/bin/env python3
"""开发验证：只下载固定运行库/TN wheel 到 build/；不安装 Python 包，不播放声音。"""
import hashlib
import json
from pathlib import Path
import urllib.request
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'pocket/assets/package.json').read_text())
cache = root / 'build/pocket-check/downloads'
cache.mkdir(parents=True, exist_ok=True)
for asset in manifest['downloads']:
    if not asset['name'].endswith('.whl'):
        continue
    target = cache / asset['name']
    if not target.exists():
        with urllib.request.urlopen(asset['url'], timeout=60) as response, target.open('wb') as output:
            size = 0
            while data := response.read(65536):
                size += len(data)
                if size > 100_000_000:
                    raise ValueError('download exceeds limit')
                output.write(data)
    assert hashlib.sha256(target.read_bytes()).hexdigest() == asset['sha256']
    print(asset['name'], target.stat().st_size, 'SHA256 OK', flush=True)
