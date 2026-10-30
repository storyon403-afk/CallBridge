#!/usr/bin/env python3
"""本文件的目的：准备固定官方 Node 运行时；有界下载、核对摘要，只提取程序和许可，不执行归档内容。"""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'release/node-runtime.json').read_text())
OUT = ROOT / 'rust/build/release-runtime'
CACHE = ROOT / 'rust/build/release-downloads'
CACHE.mkdir(parents=True, exist_ok=True)
archive = CACHE / LOCK['archive']
if not archive.exists():
    partial = CACHE / (LOCK['archive'] + '.partial')
    subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
                    '--max-filesize', '100000000', '--max-time', '1800', '--continue-at', '-',
                    '--silent', '--show-error', '--output', str(partial), LOCK['url']], check=True)
    if hashlib.sha256(partial.read_bytes()).hexdigest() != LOCK['sha256']:
        raise SystemExit('Node archive checksum mismatch')
    partial.rename(archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != LOCK['sha256']:
    raise SystemExit('Cached Node archive checksum mismatch; cache was not overwritten')
OUT.mkdir(parents=True, exist_ok=True)
prefix = LOCK['archive'].removesuffix('.tar.xz')
with tarfile.open(archive, 'r:xz') as tar:
    for source, name, limit in [('bin/node', 'node', 150_000_000), ('LICENSE', 'NODE-LICENSE', 1_000_000)]:
        entry = tar.getmember(prefix + '/' + source)
        if not entry.isfile() or not 0 < entry.size <= limit:
            raise SystemExit('Unexpected Node archive entry')
        data = tar.extractfile(entry).read(limit + 1)
        if len(data) != entry.size:
            raise SystemExit('Node archive entry size mismatch')
        (OUT / name).write_bytes(data)
(OUT / 'node').chmod(0o755)
(OUT / 'provenance.json').write_text(json.dumps({**LOCK, 'binary_sha256': hashlib.sha256((OUT/'node').read_bytes()).hexdigest()}, indent=2)+'\n')
print(OUT)
