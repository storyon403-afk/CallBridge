#!/usr/bin/env python3
"""离线核对 Windows 包的文件、PE 架构、导入库与 FFI 导出；不替代 Windows 运行检查。"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def pe(data):
    assert data[:2] == b'MZ'
    offset = struct.unpack_from('<I', data, 60)[0]
    assert data[offset:offset+4] == b'PE\0\0'
    machine, sections = struct.unpack_from('<HH', data, offset+4)
    optional_size = struct.unpack_from('<H', data, offset+20)[0]
    optional = offset+24
    magic = struct.unpack_from('<H', data, optional)[0]
    directories = optional+(112 if magic == 0x20b else 96)
    table = optional+optional_size
    def address(rva):
        for i in range(sections):
            virtual_size, virtual, size, raw = struct.unpack_from('<IIII', data, table+i*40+8)
            if virtual <= rva < virtual+max(virtual_size, size):
                return raw+rva-virtual
        raise ValueError('Invalid PE address')
    def string(rva):
        start = address(rva)
        return data[start:data.index(b'\0', start)].decode('ascii')
    imports=[]
    import_rva = struct.unpack_from('<I', data, directories+8)[0]
    if import_rva:
        entry = address(import_rva)
        while any(data[entry:entry+20]):
            imports.append(string(struct.unpack_from('<I', data, entry+12)[0]).lower())
            entry+=20
    exports=set()
    export_rva = struct.unpack_from('<I', data, directories)[0]
    if export_rva:
        entry=address(export_rva)
        count=struct.unpack_from('<I', data, entry+24)[0]
        names=struct.unpack_from('<I', data, entry+32)[0]
        if names:
            start=address(names)
            exports={string(struct.unpack_from('<I',data,start+4*i)[0]) for i in range(count)}
    return machine, imports, exports

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--revision', default='')
    args=parser.parse_args()
    if args.revision and not re.fullmatch(r'[a-z0-9]+', args.revision):
        parser.error('revision must contain only lowercase letters and digits')
    info=plistlib.loads((ROOT/'rust/native/Info.plist').read_bytes())
    version=info['CFBundleShortVersionString']
    name=f'CallBridge-{version}-windows-x64'+('-'+args.revision if args.revision else '')
    folder=ROOT/'rust/build/releases'/version
    archive=folder/(name+'.zip')
    sums='WINDOWS-'+args.revision+'-SHA256SUMS' if args.revision else 'WINDOWS-SHA256SUMS'
    expected=(folder/sums).read_text().split()[0]
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected
    with zipfile.ZipFile(archive) as z:
        names=z.namelist()
        assert len(names)==len(set(names))
        for n in names:
            assert n.startswith(name+'/') and '..' not in PurePosixPath(n).parts and '\\' not in n
            assert not any(p in {'.git','.env','__pycache__','node_modules'} for p in PurePosixPath(n).parts)
        manifest=json.loads(z.read(name+'/MANIFEST.json'))
        assert manifest.get('revision','')==args.revision
        assert manifest['version']==version and manifest['build']==info['CFBundleVersion']
        payload={e['path']:e for e in manifest['files']}
        assert set(names)=={name+'/'+p for p in payload}|{name+'/MANIFEST.json'}
        for path,item in payload.items():
            data=z.read(name+'/'+path)
            assert len(data)==item['bytes'] and hashlib.sha256(data).hexdigest()==item['sha256'],path
        required=['CallBridge.exe','CallBridge.CoreChecks.exe','CallBridge.runtimeconfig.json','callbridge_abi_probe.dll',
                  'libunwind.dll','runtime/node.exe','camera/callbridge-camera-sender.exe','camera/callbridge_abi_probe.dll',
                  'camera/libunwind.dll','camera/python/python.exe','camera/python/MSVCP140.dll',
                  'avatar/index.html','avatar/app.js','avatar-host/server.mjs','avatar-host/cloud/service.mjs',
                  'Test-Windows.cmd','camera/check_bridge.mjs','README.md','licenses/LLVM-MINGW-LICENSE.TXT',
                  'studio/cheng.png','studio/coast-evening.jpg','studio/window-morning.jpg',
                  'UI-ACCEPTANCE.md','avatar/preview.jpg','cloud-guides/api.md','cloud-guides/decart.md']
        assert all(p in payload for p in required)
        system={'kernel32.dll','ntdll.dll','advapi32.dll','crypt32.dll','iphlpapi.dll','oleaut32.dll','propsys.dll',
                'rpcrt4.dll','user32.dll','version.dll','winmm.dll','ws2_32.dll','bcrypt.dll','ole32.dll','userenv.dll',
                'dbghelp.dll','psapi.dll','shell32.dll','shlwapi.dll','winhttp.dll'}
        count=0
        for path in payload:
            if path in required[:2] or path.startswith(('camera/','runtime/')) or path in {'callbridge_abi_probe.dll','libunwind.dll'}:
                if not path.endswith(('.exe','.dll','.pyd')): continue
                machine,imports,exports=pe(z.read(name+'/'+path))
                assert machine==0x8664, path+': not x64'
                available={PurePosixPath(p).name.lower() for p in payload if PurePosixPath(p).parent==PurePosixPath(path).parent}
                if path.startswith('camera/'):
                    available|={PurePosixPath(p).name.lower() for p in payload if p.startswith('camera/python/')}
                for dll in imports:
                    assert dll in available or dll in system or dll.startswith(('api-ms-win-','ext-ms-win-')),path+': missing '+dll
                if path=='callbridge_abi_probe.dll':
                    code=(ROOT/'rust/windows/CallBridge.Windows/Core.cs').read_text()
                    needed=set(re.findall(r'extern\s+\w+\s+(cb_\w+)\(',code))|{'cb_video_start','cb_video_stop','cb_video_accept'}
                    assert needed<=exports, 'Missing Rust exports: '+str(needed-exports)
                count+=1
        print(json.dumps({'passed':True,'files':len(payload),'x64_binaries_checked':count,'windows_execution_verified':False}))

if __name__=='__main__': main()
