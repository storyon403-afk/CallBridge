#!/usr/bin/env python3
"""验证自动更新配置和真实签名拒绝路径；临时载荷不能执行，也不会安装更新。
签名工具仅访问已有发布钥匙串账户，不导出私钥、不请求音视频设备。
"""
import copy
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from update_release import ACCOUNT, FEED_URL, NS, ROOT, TOOLS, RELEASE_URL, check_signing_key, verify_feed


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='update-check-', dir=ROOT / 'rust/build')
        self.addCleanup(self.tmp.cleanup)
        self.info = plistlib.loads((ROOT / 'rust/native/Info.plist').read_bytes())
        self.archive = Path(self.tmp.name) / f'CallBridge-{self.info["CFBundleShortVersionString"]}-macos-arm64.zip'
        self.archive.write_bytes(b'Inert signature verification fixture; not an application.')
        signature = subprocess.check_output([str(TOOLS / 'sign_update'), '--account', ACCOUNT,
                                             '-p', str(self.archive)], text=True).strip()
        ET.register_namespace('sparkle', NS[1:-1])
        rss = ET.Element('rss', version='2.0')
        channel = ET.SubElement(rss, 'channel')
        ET.SubElement(channel, 'title').text = 'CallBridge test'
        item = ET.SubElement(channel, 'item')
        for field, key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString'),
                           ('minimumSystemVersion', 'LSMinimumSystemVersion')]:
            ET.SubElement(item, NS + field).text = self.info[key]
        ET.SubElement(item, NS + 'hardwareRequirements').text = 'arm64'
        ET.SubElement(item, 'enclosure', {'url': RELEASE_URL + 'download/v' + self.info['CFBundleShortVersionString'] + '/' + self.archive.name,
                                         'length': str(self.archive.stat().st_size), NS + 'edSignature': signature})
        self.feed = Path(self.tmp.name) / 'appcast.xml'
        ET.ElementTree(rss).write(self.feed, encoding='utf-8', xml_declaration=True)
        subprocess.run([str(TOOLS / 'sign_update'), '--account', ACCOUNT, str(self.feed)], check=True, capture_output=True)

    def test_defaults_and_valid_signatures(self):
        info = self.info
        self.assertFalse(info['CBEnableUpdates'])
        self.assertEqual(info['SUFeedURL'], FEED_URL)
        self.assertEqual(info['SUScheduledCheckInterval'], 86400)
        for key in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed'):
            self.assertIs(info[key], True)
        self.assertEqual(info['SUSignedFeedFailureExpirationInterval'], 0)
        self.assertFalse(info['SUEnableSystemProfiling'])
        verify_feed(self.feed, self.archive, info)

    def test_tampered_archive_same_length(self):
        data = bytearray(self.archive.read_bytes())
        data[0] ^= 1
        self.archive.write_bytes(data)
        with self.assertRaises(subprocess.CalledProcessError):
            verify_feed(self.feed, self.archive, self.info)

    def test_tampered_feed(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(b'CallBridge test', b'CallBridge evil'))
        with self.assertRaises(subprocess.CalledProcessError):
            verify_feed(self.feed, self.archive, self.info)

    def test_wrong_version(self):
        info = copy.copy(self.info)
        info['CFBundleVersion'] = str(int(info['CFBundleVersion']) + 1)
        with self.assertRaises(ValueError):
            verify_feed(self.feed, self.archive, info)

    def test_wrong_public_key(self):
        info = copy.copy(self.info)
        info['SUPublicEDKey'] = 'Incorrect public key'
        with self.assertRaises(ValueError):
            check_signing_key(info)

    def test_truncated_archive(self):
        self.archive.write_bytes(self.archive.read_bytes()[:-1])
        with self.assertRaises(ValueError):
            verify_feed(self.feed, self.archive, self.info)


def native_checks():
    binary = ROOT / 'rust/build/updater-check'
    framework = ROOT / 'rust/build/sparkle'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                    '-I', str(ROOT / 'rust/native'), '-F', str(framework),
                    '-Wl,-rpath,' + str(framework), '-framework', 'Sparkle', '-framework', 'AppKit',
                    str(ROOT / 'rust/native/app_updater.m'), str(ROOT / 'rust/native/localization.m'),
                    str(ROOT / 'rust/tests/updater_check.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    native_checks()
    unittest.main()
