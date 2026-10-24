#!/usr/bin/env python3
"""本文件的目的：核对三语言词表覆盖和格式占位符，不启动 App 或音视频。"""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('zh-Hans', 'en', 'ja')

def read_table(language):
    path = ROOT / 'native/locales' / (language + '.lproj') / 'Localizable.strings'
    subprocess.run(['plutil', '-lint', str(path)], check=True, capture_output=True)
    pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");', path.read_text())
    table = {json.loads(key): json.loads(value) for key, value in pairs}
    assert len(pairs) == len(table), 'duplicate translation keys'
    return table

def formats(text):
    return re.findall(r'%(?:\d+\$)?[-+#0]*(?:\d+)?(?:\.\d+)?(?:ll|l|z)?[@diuoxXfFeEgGcsp]', text.replace('%%', ''))

tables = {lang: read_table(lang) for lang in LANGUAGES}
base = tables['zh-Hans']
for lang, table in tables.items():
    assert table.keys() == base.keys(), (lang, 'missing keys')
    for key, value in table.items():
        assert value, (lang, key, 'empty translation')
        assert formats(key) == formats(value), (lang, key, 'format mismatch')
for name in ('app.m', 'avatar_panel.m', 'personal_voice.m', 'window_workspace.m', 'localization.m'):
    source = (ROOT / 'native' / name).read_text()
    for raw in re.findall(r'CBL\(@("(?:[^"\\]|\\.)*")\)', source):
        assert json.loads(raw) in base, (name, raw, 'missing translation')
# 语音样本和用户数据不能混入 UI 词表。
assert '你好，这是我的声音。欢迎使用 CallBridge。' not in base
assert '你好，这是 CallBridge 发送器测试。' not in base
print(json.dumps({'passed': True, 'languages': LANGUAGES, 'entries': len(base), 'audio_io_started': False}))
