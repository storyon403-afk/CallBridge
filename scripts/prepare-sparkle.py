#!/usr/bin/env python3
"""准备锁定的 Sparkle 框架和发布工具；先校验完整归档，再保留框架符号链接解压。
构建脚本只读取此缓存；联网准备必须显式执行，不在普通构建中下载依赖。
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    lock = json.loads((ROOT / 'release/sparkle.json').read_text())
    cache = ROOT / 'rust/build/sparkle-download'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / lock['archive']
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=cache) as tmp:
            partial = Path(tmp) / 'download'
            subprocess.run(['curl', '--fail', '--location', '--proto', '=https',
                            '--proto-redir', '=https', '--max-filesize', '100000000',
                            '--max-time', '600', '--silent', '--show-error',
                            '--output', str(partial), lock['url']], check=True)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != lock['sha256']:
                raise SystemExit('Sparkle archive checksum mismatch')
            partial.rename(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['sha256']:
        raise SystemExit('Cached Sparkle archive checksum mismatch')
    out = ROOT / 'rust/build/sparkle'
    out.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:xz') as tar:
        # data 过滤器拒绝越界路径/链接；只提取集成需要的内容，不带示例 App。
        members = [m for m in tar.getmembers() if m.name.split('/')[0] in
                   {'Sparkle.framework', 'bin', 'LICENSE'}]
        tar.extractall(out, members=members, filter='data')
    subprocess.run(['codesign', '--verify', '--deep', '--strict',
                    str(out / 'Sparkle.framework')], check=True)
    (out / 'provenance.json').write_text(json.dumps(lock, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
