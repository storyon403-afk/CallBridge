#!/usr/bin/env python3
"""本文件的目的：扫描待发布文件中的密钥形态和缺失源码引用；只记录文件名和规则名，不输出命中值。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_files', ROOT/'scripts/release-files.py')
policy = importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)
files = policy.files()
patterns = {
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'huggingface-token': rb'\bhf_[a-zA-Z0-9]{25,}\b',
    'github-token': rb'\b(?:gh[pousr]_[a-zA-Z0-9]{30,}|github_pat_[a-zA-Z0-9_]{40,})\b',
    'aws-access-key': rb'\bAKIA[0-9A-Z]{16}\b',
}
issues=[]; inventory=[]
for name in files:
    data=(ROOT/name).read_bytes()
    inventory.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    for rule,pattern in patterns.items():
        if re.search(pattern,data): issues.append({'path':name,'rule':rule})
# 引用源码必须随包提供；绝不以“在开发缓存能编译”当作源码齐全。
for name in ['rust/scripts/build-app.sh','rust/scripts/build-camera.sh']:
    script=(ROOT/name).read_text()
    for reference in re.findall(r'\bnative/[A-Za-z0-9_./-]+\.(?:m|c)(?![A-Za-z0-9_.-])',script):
        if 'rust/'+reference not in files:issues.append({'path':reference,'rule':'missing-native-source'})
for name in files:
    if name.endswith('.rs'):
        for reference in re.findall(r'include_(?:str|bytes)!\("([^"]+)"\)',(ROOT/name).read_text()):
            candidate=(ROOT/name).parent/reference
            relative=candidate.resolve().relative_to(ROOT).as_posix()
            if relative not in files:issues.append({'path':relative,'rule':'missing-embedded-source'})
report={'passed':not issues,'files':len(inventory),'issues':issues,'inventory':inventory,'scope':'Current release inputs only; no claim about all Git history or unknown vulnerabilities.'}
out=ROOT/'build/security';out.mkdir(parents=True,exist_ok=True)
(out/'source.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='inventory'},ensure_ascii=False))
sys.exit(bool(issues))
