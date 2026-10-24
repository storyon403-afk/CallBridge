#!/usr/bin/env python3
"""本文件的目的：按白名单打包 GitHub Pages；不复制本地文档、模型、设置或开发缓存。"""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'website'
OUTPUT = ROOT / 'build/site'
OUTPUT.mkdir(parents=True, exist_ok=True)
(OUTPUT / 'media').mkdir(exist_ok=True)
for name in ('index.html', 'style.css', 'site.js', 'content.js', 'experience.js'):
    shutil.copy2(SOURCE / name, OUTPUT / name)
# 产品图标保持原文件；动画是单独的小体积展示资源，不把引擎打进网页。
shutil.copy2(ROOT / 'icon/icon.png', OUTPUT / 'media/icon.png')
shutil.copy2(ROOT / 'assets/diagrams/04.png', OUTPUT / 'media/personal-voice.png')
for index in range(1, 4):
    shutil.copy2(ROOT / f'assets/demos/effect-{index:02}-local.mp4', OUTPUT / f'media/effect-{index:02}.mp4')
    shutil.copy2(ROOT / f'assets/demos/effect-{index:02}-poster.jpg', OUTPUT / f'media/effect-{index:02}-poster.jpg')
for path in (SOURCE / 'media').iterdir():
    if path.is_file() and path.suffix.lower() in ('.mp4', '.webm', '.jpg', '.png', '.webp', '.gif', '.svg'):
        shutil.copy2(path, OUTPUT / 'media' / path.name)
(OUTPUT / '.nojekyll').write_text('')
print(OUTPUT)
