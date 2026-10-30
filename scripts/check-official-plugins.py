#!/usr/bin/env python3
"""目的：用真实目录解析器、归档校验和 Rust 安装器验证官方包；全部写入临时目录，不联网或使用设备。"""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'rust/build/app/CallBridge.app/Contents/MacOS/CallBridge'
WORKER=APP.parent/'callbridge-pocket'
INDEX=ROOT/'plugins/official/catalog.json'
PACKS=ROOT/'build/official-plugins/plugins-v1'

class OfficialTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cb-official-check-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.catalog=json.loads(INDEX.read_text())
    def command(self,args,success=True):
        run=subprocess.run([str(a) for a in args],capture_output=True,text=True)
        self.assertEqual(run.returncode==0,success,run.stderr[-800:]);return run
    def validate(self,index,success):
        file=self.root/'catalog.json';file.write_text(json.dumps(index));self.command([APP,'--official-catalog-check',file],success)
    def test_catalog_and_reproducible_packages(self):
        self.command(['python3',ROOT/'scripts/package-official-plugins.py','--check'])
        self.validate(self.catalog,True)
        for p in self.catalog['plugins']:
            archive=PACKS/p['url'].rsplit('/',1)[1]
            self.command([APP,'--official-archive-check',INDEX,archive])
            unpack=self.root/p['id'];unpack.mkdir()
            with zipfile.ZipFile(archive) as z:z.extractall(unpack)
            self.command([WORKER,'plugin-check',unpack])
    def test_untrusted_catalog_rejected(self):
        patches=[{'url':'http://github.com/a.cbplugin'},{'url':'https://example.com/a.cbplugin'},
                 {'url':'https://github.com/other/CallBridge/releases/download/plugins-v1/x.cbplugin'},
                 {'url':'https://github.com/storyon403-afk/CallBridge/releases/download/plugins-v1/../x.cbplugin'},
                 {'bytes':300000001},{'bytes':-1},{'bytes':1.5},{'sha256':'bad'},{'published':'true'},
                 {'kind':'script'},{'version':'01.0.0'},{'names':{'en':'Missing translations'}},{'dependencies':[{'id':'unknown','version':'1.0.0'}]}]
        for patch in patches:
            with self.subTest(patch=patch):
                data=copy.deepcopy(self.catalog);data['plugins'][0].update(patch);self.validate(data,False)
        duplicate=copy.deepcopy(self.catalog);duplicate['plugins'].append(duplicate['plugins'][0]);self.validate(duplicate,False)
    def test_tampered_or_truncated_archive_rejected(self):
        p=self.catalog['plugins'][0];name=p['url'].rsplit('/',1)[1];data=(PACKS/name).read_bytes();path=self.root/name
        for bad in [data[:-1],data+b'x',bytes([data[0]^1])+data[1:]]:
            path.write_bytes(bad);self.command([APP,'--official-archive-check',INDEX,path],False)
    def test_install_identity_duplicate_and_dependency(self):
        for p in self.catalog['plugins']:
            target=self.root/p['id']/'Plugins/Local';archive=PACKS/p['url'].rsplit('/',1)[1]
            command=[WORKER,'plugin-install-official',archive,target,p['kind']]
            self.command(command+['org.callbridge.wrong',p['version']],False)
            self.assertFalse((target/p['id']).exists())
            self.command(command+[p['id'],'9.9.9'],False)
            self.assertFalse((target/p['id']).exists())
            needs_engine=bool(p['dependencies'])
            self.command(command+[p['id'],p['version']],not needs_engine)
            if not needs_engine:
                installed=target/p['id']/p['version']/'manifest.json';before=hashlib.sha256(installed.read_bytes()).hexdigest()
                self.command(command+[p['id'],p['version']],False)
                self.assertEqual(before,hashlib.sha256(installed.read_bytes()).hexdigest())
            else:self.assertFalse((target/p['id']).exists())

if __name__=='__main__':unittest.main()
