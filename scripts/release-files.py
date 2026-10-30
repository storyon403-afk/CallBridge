#!/usr/bin/env python3
"""本文件的目的：为源码包和安全扫描提供统一白名单；包含未提交源码，排除私人数据及本地缓存。"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'CB', 'CBT', '.gitignore', 'LICENSE', 'NOTICE', 'LICENSING.md',
              'README.md', 'README.en.md', 'README.zh-CN.md', 'GETTING_STARTED.md',
              'SECURITY.md', 'RELEASING.md', 'THIRD_PARTY_NOTICES.md', 'schedule.md', 'graph.md', '插件接入教程.md'}
PREFIXES = ('rust/src/', 'rust/native/', 'rust/include/', 'rust/tests/', 'rust/examples/', 'rust/scripts/',
            'rust/pocket/', 'rust/avatar/', 'scripts/', 'release/', 'plugins/', 'website/', '.github/', 'icon/', 'assets/')
BLOCKED = {'build', 'target', 'node_modules', '__pycache__', '.git', '.env', 'reference'}

def files(root=ROOT):
    root = Path(root).resolve()
    if (root / '.git').exists():
        names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).decode().split('\0')
    else:
        # 从已导出的源码包重建时没有 Git；仍应用完全相同的白名单。
        names = [p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()]
    result = []
    for name in sorted(set(names)):
        p = root / name
        if not name or name == 'release/VALIDATION.md' or any(part in BLOCKED for part in Path(name).parts) or p.suffix in {'.pyc', '.p12', '.mobileprovision'}:
            continue
        if name not in ROOT_FILES and name not in {'rust/Cargo.toml','rust/Cargo.lock'} and not name.startswith(PREFIXES):
            continue
        if p.is_symlink():
            raise ValueError('Source release cannot contain links: ' + name)
        if p.is_file():
            result.append(name)
    return result

if __name__ == '__main__':
    print('\n'.join(files()))
