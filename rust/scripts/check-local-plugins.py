#!/usr/bin/env python3
"""本文件的目的：以临时资源包验证真实导入、拒绝与回滚；不接触用户插件或设备。"""
import hashlib,json,os,struct,subprocess,tempfile,unittest,zipfile,zlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORKER=ROOT/'target/release/callbridge-pocket'
class ImportTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='cb-plugin-');self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name).resolve();self.source=self.root/'source';self.source.mkdir();self.dest=self.root/'Plugins/Local'
  data=b'{"schema":1,"algorithm":"spectral-floor-v1","strength":0.5}'
  (self.source/'settings.json').write_bytes(data)
  self.manifest=dict(schema=1,api=1,id='org.example.clean',version='1.0.0',name='Clean',kind='audio-denoise',core_min='0.13.0',core_max='0.14.0',platforms=['any'],dependencies=[],permissions=[],license='CC0-1.0',author='Test',entry='settings.json',files=[dict(path='settings.json',bytes=len(data),sha256=hashlib.sha256(data).hexdigest())]);self.save()
 def save(self): (self.source/'manifest.json').write_text(json.dumps(self.manifest))
 def run_worker(self,*args,ok=True):
  r=subprocess.run([str(WORKER),*map(str,args)],capture_output=True,text=True,timeout=20)
  self.assertEqual(r.returncode==0,ok,r.stderr);return r.stdout
 def install(self,source=None,ok=True,kind='audio-denoise'):
  return self.run_worker('plugin-import',source or self.source,self.dest,kind,ok=ok)
 def test_directory_install_duplicate_and_latest(self):
  info=json.loads(self.install());self.assertEqual(info['strength'],.5);self.install(ok=False)
  self.manifest['version']='1.1.0';self.save();self.install()
  result=json.loads(self.run_worker('plugin-list',self.dest));self.assertEqual(result['plugins'][0]['version'],'1.1.0')
  (self.dest/'org.example.clean/1.1.0/settings.json').write_text('{}')
  result=json.loads(self.run_worker('plugin-list',self.dest));self.assertEqual(result['plugins'],[]);self.assertEqual(result['invalid'],1)
 def test_hash_extra_files_type_and_rollback(self):
  (self.source/'settings.json').write_text('{}');self.install(ok=False)
  self.assertEqual(list(self.dest.iterdir()),[])
 def test_extra_file_and_wrong_entrypoint(self):
  (self.source/'code.sh').write_text('exit 0');self.install(ok=False)
 def test_wrong_category_and_permissions(self):
  self.install(kind='voice-en',ok=False)
  self.manifest['permissions']=['network'];self.save();self.install(ok=False)
 def test_symlink_rejected(self):
  data=(self.source/'settings.json').read_bytes();(self.root/'outside.json').write_bytes(data)
  (self.source/'settings.json').unlink();(self.source/'settings.json').symlink_to(self.root/'outside.json');self.install(ok=False)
 def archive(self,extra=None):
  path=self.root/'test.cbplugin'
  with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
   for p in self.source.iterdir(): z.write(p,p.name)
   if extra:z.writestr(*extra)
  return path
 def test_zip_install(self): self.install(self.archive())
 def test_zip_permissions_and_links(self):
  # 不继承不可信归档的提权位；ZIP 内的符号链接必须在写入正式目录之前被拒绝。
  def make_zip(mode):
   path=self.root/'mode.cbplugin'
   with zipfile.ZipFile(path,'w') as z:
    z.write(self.source/'manifest.json','manifest.json')
    entry=zipfile.ZipInfo('settings.json');entry.create_system=3;entry.external_attr=mode<<16
    z.writestr(entry,(self.source/'settings.json').read_bytes())
   return path
  self.install(make_zip(0o120777),ok=False)
  self.install(make_zip(0o106755))
  installed=self.dest/'org.example.clean/1.0.0/settings.json'
  self.assertEqual(installed.stat().st_mode&0o6000,0)
 def test_neural_self_declared_executable_is_rejected(self):
  # 包内清单即使与伪造程序摘要一致，也不能绕过宿主锁定的官方程序摘要。
  (self.source/'settings.json').write_text('{"schema":1,"algorithm":"deepfilter-v3","strength":0.5}')
  for name in ['deep-filter','LICENSE-MIT','LICENSE-APACHE','NOTICE.txt']:(self.source/name).write_text('replacement')
  self.manifest['platforms']=['macos-arm64'];self.manifest['core_min']='0.13.9'
  self.manifest['files']=[dict(path=p.name,bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in self.source.iterdir() if p.name!='manifest.json'];self.save()
  self.install(ok=False)
  self.assertEqual(list(self.dest.iterdir()),[])
 def test_spectral_preset_cannot_smuggle_declared_executable(self):
  p=self.source/'deep-filter';p.write_bytes(b'executable')
  self.manifest['files'].append(dict(path=p.name,bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()));self.save();self.install(ok=False)
 def test_zip_traversal_and_duplicate(self):
  self.install(self.archive(('../escape',b'x')),ok=False);self.assertFalse((self.root/'escape').exists())
  self.install(self.archive(('settings.json',b'{}')),ok=False)
 def test_bad_version_dependency_and_config(self):
  self.manifest['core_min']='0.14.0';self.save();self.install(ok=False)
  self.manifest['core_min']='0.13.0';self.manifest['dependencies']=[dict(id='unknown',version='1.0.0')];self.save();self.install(ok=False)
 def test_catalog_mismatch_isolated(self):
  self.install()
  other=self.dest/'org.example.other/1.0.0';other.mkdir(parents=True)
  for name in ['manifest.json','settings.json']:(other/name).write_bytes((self.source/name).read_bytes())
  result=json.loads(self.run_worker('plugin-list',self.dest))
  self.assertEqual(len(result['plugins']),1);self.assertEqual(result['invalid'],1)
 def test_catalog_invalid_versions_cannot_hide_newest(self):
  self.install()
  other=self.dest/'org.example.too-many';other.mkdir()
  for n in range(65):(other/f'invalid-{n}').mkdir()
  result=json.loads(self.run_worker('plugin-list',self.dest))
  self.assertEqual(len(result['plugins']),1);self.assertEqual(result['invalid'],1)
 def test_parent_symlink_rejected(self):
  linked=self.root/'linked';linked.symlink_to(self.source,target_is_directory=True)
  self.run_worker('plugin-check',linked,ok=False)
 def test_safetensor_wrong_layout(self):
  p=self.root/'voice.safetensors';header=json.dumps({'x':dict(dtype='F32',shape=[2],data_offsets=[0,8])}).encode();p.write_bytes(struct.pack('<Q',len(header))+header+b'\0'*8)
  self.run_worker('english-tensor-check',p,ok=False)
 def test_corrupt_media_rejected(self):
  data=b'\x89PNG\r\n\x1a\nBAD';(self.source/'settings.json').unlink();(self.source/'image.png').write_bytes(data)
  self.manifest.update(kind='background-image',entry='image.png',dependencies=[dict(id='avatar-holistic-v1',version='1.0.0')],files=[dict(path='image.png',bytes=len(data),sha256=hashlib.sha256(data).hexdigest())]);self.save()
  self.run_worker('plugin-check',self.source,ok=False)
 def test_removed_portrait_type_rejected(self):
  self.manifest['kind']='avatar-portrait';self.save();self.install(ok=False,kind='avatar-portrait')
if __name__=='__main__': unittest.main(verbosity=2)
