"""本文件的目的：真实执行原生帧解析/像素转换/CM 时间戳路径，仅内存，不枚举或启动视频设备。"""
import json
import struct
import subprocess
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
binary = root / 'build/camera/CallBridge Camera.app/Contents/MacOS/callbridge-camera-sender'
size = 1280 * 720 * 4
rgba = bytes([12, 34, 56, 255]) * (1280 * 720)
checks = []

def begin():
    p = subprocess.Popen([str(binary), '--memory-check'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert json.loads(p.stdout.readline())['ready'] is True
    return p

def send(p, seq, frame=rgba, age=0, length=size):
    p.stdin.write(struct.pack('<4sIQQ', b'CBV1', length, seq, age))
    p.stdin.write(frame)
    p.stdin.flush()
    return json.loads(p.stdout.readline())

def finish(p):
    p.stdin.close()
    result = p.wait(timeout=4)
    lines = [json.loads(line) for line in p.stdout if line.strip()]
    assert lines[-1]['stopped'] is True
    return result, lines

p = begin()
try:
    first = send(p, 1)
    assert first['accepted'] and first['firstBGRA'] == [56, 34, 12, 255] and first['bytes'] == size, first
    assert send(p, 1)['accepted'] is False
    assert send(p, 2)['accepted'] is True
    assert finish(p)[0] == 0
    checks.append('RGBA→BGRA/sample buffer/重复序号拒绝/正常EOF')
finally:
    if p.poll() is None: p.kill(); p.wait()

for title, header, payload, code in [
    ('尺寸拒绝', struct.pack('<4sIQQ', b'CBV1', size+1, 1, 0), b'', 6),
    ('协议版本拒绝', struct.pack('<4sIQQ', b'CBV2', size, 1, 0), b'', 6),
    ('年龄超限拒绝', struct.pack('<4sIQQ', b'CBV1', size, 1, 500000001), b'', 6),
    ('截断帧拒绝', struct.pack('<4sIQQ', b'CBV1', size, 1, 0), rgba[:10], 6),
    ('透明原始图拒绝', struct.pack('<4sIQQ', b'CBV1', size, 1, 0), bytes([12, 34, 56, 0]) * (1280*720), 8),
]:
    p = begin()
    try:
        p.stdin.write(header + payload);p.stdin.flush()
        assert finish(p)[0] == code, title
        checks.append(title)
    finally:
        if p.poll() is None: p.kill(); p.wait()

p = begin()
try:
    start = time.monotonic()
    assert p.wait(timeout=3) == 0
    assert time.monotonic() - start < 2.5
    checks.append('无人喂帧自动退出')
finally:
    if p.poll() is None: p.kill(); p.wait()

denied = subprocess.run([str(binary), '--send'], capture_output=True, timeout=3)
assert denied.returncode == 2
checks.append('缺少主动输出确认拒绝')
report = {'passed': True, 'checks': checks, 'physicalCameraOpened': False, 'virtualDeviceStarted': False}
path = root / 'build/camera/memory-report.json'
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False))
