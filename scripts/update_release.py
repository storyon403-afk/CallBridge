#!/usr/bin/env python3
"""更新发行契约：核对钥匙串公钥，生成签名 feed，并检查 feed 与最终归档是否一致。
只操作本地发行产物；不上传 GitHub，不导出私钥，也不修改用户安装的 App。
"""
from pathlib import Path
import subprocess
import tempfile
import os
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'rust/build/sparkle/bin'
ACCOUNT = 'dev.callbridge.demo'
RELEASE_URL = 'https://github.com/storyon403-afk/CallBridge/releases/'
FEED_URL = RELEASE_URL + 'latest/download/appcast.xml'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def check_signing_key(info):
    # -p 仅查询公钥，绝不生成替换密钥或把私钥放进构建目录。
    public = subprocess.check_output([str(TOOLS / 'generate_keys'), '--account', ACCOUNT, '-p'], text=True).strip()
    if public != info['SUPublicEDKey']:
        raise ValueError('Sparkle signing key does not match SUPublicEDKey; restore the original release key')


def generate_feed(archive, info):
    check_signing_key(info)
    feed = archive.parent / 'appcast.xml'
    # 单独目录只含 App ZIP，避免把 source.tar.gz 或旧版本当成应用更新。
    with tempfile.TemporaryDirectory(prefix='appcast-', dir=archive.parent) as tmp:
        os.link(archive, Path(tmp) / archive.name)
        subprocess.run([str(TOOLS / 'generate_appcast'), '--account', ACCOUNT,
                        '--download-url-prefix', RELEASE_URL + 'download/v' + info['CFBundleShortVersionString'] + '/',
                        '--maximum-deltas', '0', '-o', str(feed), tmp], check=True)
    verify_feed(feed, archive, info)
    return feed


def verify_feed(feed, archive, info):
    check_signing_key(info)
    # XML 签名保护版本和 URL；归档签名保护实际可执行内容，两层都必须通过。
    subprocess.run([str(TOOLS / 'sign_update'), '--account', ACCOUNT, '--verify', str(feed)],
                   check=True, capture_output=True)
    items = ET.parse(feed).findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one stable update')
    item = items[0]
    enclosure = item.find('enclosure')
    expected_url = RELEASE_URL + 'download/v' + info['CFBundleShortVersionString'] + '/' + archive.name
    if (item.findtext(NS + 'version') != info['CFBundleVersion'] or
            item.findtext(NS + 'shortVersionString') != info['CFBundleShortVersionString'] or
            item.findtext(NS + 'minimumSystemVersion') != info['LSMinimumSystemVersion'] or
            item.findtext(NS + 'hardwareRequirements') != 'arm64' or
            enclosure is None or enclosure.get('url') != expected_url or
            enclosure.get('length') != str(archive.stat().st_size)):
        raise ValueError('Appcast version, system/hardware requirement, URL, or archive size mismatch')
    signature = enclosure.get(NS + 'edSignature')
    if not signature:
        raise ValueError('Missing archive signature')
    subprocess.run([str(TOOLS / 'sign_update'), '--account', ACCOUNT, '--verify', str(archive), signature],
                   check=True, capture_output=True)
