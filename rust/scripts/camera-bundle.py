"""本文件的目的：生成摄像头 bundle 元数据，签名前核对本地描述文件，不自动安装。"""
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

out, mode = Path(sys.argv[1]), sys.argv[2]
app = out / 'CallBridge Camera.app'
ext = app / 'Contents/Library/SystemExtensions/dev.callbridge.camera.extension.systemextension'
team = os.environ.get('CB_CAMERA_TEAM', '') if mode == 'signed' else ''
if mode == 'signed' and not re.fullmatch('[A-Z0-9]{10}', team):
    raise SystemExit('Team ID 必须为十位大写字母/数字')
group = f'{team or "UNSIGNED00"}.dev.callbridge.camera'
host_id, ext_id = 'dev.callbridge.camera.host', 'dev.callbridge.camera.extension'

def write(path, data):
    path.write_bytes(plistlib.dumps(data))

def profile(env, bundle_id, target, needed):
    path = Path(os.environ[env]).expanduser()
    raw = subprocess.check_output(['security', 'cms', '-D', '-i', str(path)])
    data = plistlib.loads(raw)
    ent = data.get('Entitlements', {})
    if team not in data.get('TeamIdentifier', []) or ent.get('com.apple.application-identifier') != team + '.' + bundle_id:
        raise SystemExit(f'{env}: 团队或 application identifier 不匹配')
    for key in needed:
        if not ent.get(key):
            raise SystemExit(f'{env}: 缺少 entitlement {key}')
    if group not in ent.get('com.apple.security.application-groups', []):
        raise SystemExit(f'{env}: 缺少组 {group}')
    import datetime
    expiration = data.get('ExpirationDate')
    if expiration is None or expiration <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise SystemExit(f'{env}: 描述文件已过期')
    shutil.copyfile(path, target / 'Contents/embedded.provisionprofile')

base = dict(CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1', LSMinimumSystemVersion='26.0')
write(app / 'Contents/Info.plist', {**base, 'CFBundleIdentifier': host_id, 'CFBundleExecutable': 'CallBridgeCamera', 'CFBundleName': 'CallBridge Camera', 'NSPrincipalClass': 'NSApplication', 'CBInstallable': mode == 'signed', 'NSSystemExtensionUsageDescription': '提供 CallBridge 虚拟摄像头，将你主动启用的虚拟形象画面交给通话软件。安装本身不采集或发送。'})
write(ext / 'Contents/Info.plist', {**base, 'CFBundlePackageType': 'SYSX', 'CFBundleIdentifier': ext_id, 'CFBundleExecutable': 'CallBridgeCameraExtension', 'CFBundleName': 'CallBridge Camera Extension', 'CMIOExtension': {'CMIOExtensionMachServiceName': group}, 'CBProducerTeam': team, 'NSSystemExtensionUsageDescription': '提供经用户主动开启的 CallBridge 虚拟形象画面。', 'NSCameraUsageDescription': '向通话软件提供你主动发送的虚拟形象画面，不采集物理摄像头。'})
host_ent = {'com.apple.developer.system-extension.install': True, 'com.apple.security.application-groups': [group]}
extension_ent = {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': [group]}
if mode == 'signed':
    profile('CB_CAMERA_HOST_PROFILE', host_id, app, ['com.apple.developer.system-extension.install'])
    profile('CB_CAMERA_EXTENSION_PROFILE', ext_id, ext, [])
    for ent, identifier in [(host_ent, host_id), (extension_ent, ext_id)]:
        ent['com.apple.application-identifier'] = team + '.' + identifier
        ent['com.apple.developer.team-identifier'] = team
else:
    # 避免此前签名构建留下的描述文件与当前 ad-hoc 元数据混搭；只处理脚本自身产物。
    for bundle in (app, ext):
        embedded = bundle / 'Contents/embedded.provisionprofile'
        if embedded.exists():
            embedded.unlink()
write(out / 'host.entitlements', host_ent)
write(out / 'extension.entitlements', extension_ent)
