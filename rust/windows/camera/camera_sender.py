"""Windows 视频适配进程：复用 CBV1 管道与 Rust 帧门控，只交付最终合成 RGBA。

设备查询不创建 Camera。真正发送须显式命令行授权；EOF、超时和坏帧均终止本代会话。
pyvirtualcam 在独立进程内拥有 OBS 后端，宿主退出时 Windows Job 会终止其整个进程树。
"""
from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
from pathlib import Path
import queue
import struct
import sys
import threading
import time

WIDTH, HEIGHT = 1280, 720
FRAME_BYTES = WIDTH * HEIGHT * 4
HEADER = struct.Struct("<4sIQQ")
MAX_AGE_NS = 500_000_000


class VideoGate(ctypes.Structure):
    _fields_ = [("generation", ctypes.c_uint64), ("last_sequence", ctypes.c_uint64),
                ("started_ns", ctypes.c_uint64), ("last_pts_ns", ctypes.c_uint64),
                ("active", ctypes.c_uint32)]


class CoreGate:
    def __init__(self, library: str | Path, now: int):
        self.core = ctypes.CDLL(str(library))
        ptr = ctypes.POINTER(VideoGate)
        self.core.cb_video_start.argtypes = [ptr, ctypes.c_uint64, ctypes.c_uint64]
        self.core.cb_video_start.restype = ctypes.c_uint32
        self.core.cb_video_stop.argtypes = [ptr]
        self.core.cb_video_stop.restype = None
        self.core.cb_video_accept.argtypes = [ptr, ctypes.c_uint64, ctypes.c_uint64,
                                            ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint32]
        self.core.cb_video_accept.restype = ctypes.c_uint32
        self.state = VideoGate()
        if not self.core.cb_video_start(ctypes.byref(self.state), 1, now):
            raise ValueError("Rust 视频会话启动失败")

    def accept(self, sequence: int, age_ns: int, now: int) -> bool:
        if age_ns < 0 or age_ns > MAX_AGE_NS or age_ns > now:
            return False
        return bool(self.core.cb_video_accept(ctypes.byref(self.state), 1, sequence,
                                             now - age_ns, now, FRAME_BYTES))

    def stop(self):
        self.core.cb_video_stop(ctypes.byref(self.state))


def read_exact(stream, size: int, *, allow_eof=False):
    # 大小来自固定协议上限，不能根据不可信长度分配任意大缓冲。
    parts = bytearray(size)
    offset = 0
    while offset < size:
        chunk = stream.read(size - offset)
        if not chunk:
            if offset == 0 and allow_eof:
                return None
            raise ValueError("视频帧截断")
        parts[offset:offset + len(chunk)] = chunk
        offset += len(chunk)
    return parts


def read_packet(stream, clock=time.monotonic_ns):
    first = read_exact(stream, 1, allow_eof=True)
    if first is None:
        return None
    # 第一字节之后的头部/负载阻塞都计入帧龄；正常等待下一帧的空闲时间不计入。
    started = clock()
    header = first + read_exact(stream, HEADER.size - 1)
    magic, size, sequence, age = HEADER.unpack(header)
    if magic != b"CBV1" or size != FRAME_BYTES or sequence == 0 or age > MAX_AGE_NS:
        raise ValueError("视频帧头无效")
    data = read_exact(stream, FRAME_BYTES)
    return data, sequence, age, started


def consume(stream, camera, gate, emit, *, clock=time.monotonic_ns, timeout=1.5):
    # 读取可能阻塞在半帧；独立读线程配合有界邮箱，让主线程仍能超时关闭摄像头。
    packets = queue.Queue(maxsize=1)
    done = threading.Event()

    def reader():
        while not done.is_set():
            try:
                item = read_packet(stream, clock)
            except Exception as error:
                item = error
            while not done.is_set():
                try:
                    packets.put(item, timeout=.1)
                    break
                except queue.Full:
                    continue
            if item is None or isinstance(item, Exception):
                return

    worker = threading.Thread(target=reader, name="cb-frame-pipe", daemon=True)
    worker.start()
    try:
        while True:
            try:
                item = packets.get(timeout=timeout)
            except queue.Empty as error:
                raise TimeoutError("视频管道超时，输出已停止") from error
            if item is None:
                return
            if isinstance(item, Exception):
                raise item
            data, sequence, age, started = item
            now = clock()
            if not gate.accept(sequence, age + now - started, now):
                raise ValueError("视频帧过期、重复或会话无效")
            camera.send(data)
            emit({"sequence": sequence, "accepted": True})
    finally:
        done.set()
        gate.stop()
        # 摄像头在调用方 finally 中关闭；读线程只持有 Python 字节，不访问 Camera 或 Rust。


def installed() -> dict:
    if sys.platform != "win32":
        return {"installed": False, "error": "仅支持 Windows x64"}
    if importlib.util.find_spec("pyvirtualcam") is None or importlib.util.find_spec("numpy") is None:
        return {"installed": False, "error": "视频适配依赖缺失，请重新构建"}
    import winreg
    # 只读 DirectShow 类注册，不实例化过滤器，不打开任何摄像头。
    category = r"CLSID\{860BB310-5D01-11D0-BD3B-00A0C911CE86}\Instance"
    try:
        with winreg.OpenKey(winreg.HKEY_CLASSES_ROOT, category) as key:
            for index in range(winreg.QueryInfoKey(key)[0]):
                with winreg.OpenKey(key, winreg.EnumKey(key, index)) as item:
                    try:
                        if winreg.QueryValueEx(item, "FriendlyName")[0] == "OBS Virtual Camera":
                            return {"installed": True, "active": False}
                    except FileNotFoundError:
                        continue
    except FileNotFoundError:
        pass
    return {"installed": False, "error": "请自行安装 OBS Virtual Camera，并关闭 OBS 的虚拟摄像头输出"}


class ObsCamera:
    def __init__(self):
        import numpy as np
        import pyvirtualcam
        self.np = np
        # OBS 不接受 RGBA；上游画布已完成不透明合成，此处只去掉 alpha，保持 RGB 顺序。
        # 复用连续内存，避免跨语言后端把带步幅的三通道视图误读为紧密排列的像素。
        self.rgb = np.empty((HEIGHT, WIDTH, 3), dtype=np.uint8)
        # 固定 backend 和 device，任何失败都不得退回物理摄像头或其他虚拟设备。
        self.camera = pyvirtualcam.Camera(WIDTH, HEIGHT, 30, fmt=pyvirtualcam.PixelFormat.RGB,
                                          device="OBS Virtual Camera", backend="obs")

    def send(self, rgba):
        frame = self.np.frombuffer(rgba, dtype=self.np.uint8).reshape((HEIGHT, WIDTH, 4))
        self.np.copyto(self.rgb, frame[:, :, :3])
        self.camera.send(self.rgb)

    def close(self):
        self.camera.close()


class MemoryCamera:
    def send(self, rgba):
        if len(rgba) != FRAME_BYTES:
            raise ValueError("内存帧大小无效")

    def close(self):
        pass


def core_path():
    root = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
    return root / "callbridge_abi_probe.dll"


def main(argv=None):
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--obs-check", action="store_true")
    mode.add_argument("--obs-send", action="store_true")
    mode.add_argument("--memory-check", action="store_true")
    parser.add_argument("--confirm-virtual-video", action="store_true")
    args = parser.parse_args(argv)
    emit = lambda value: print(json.dumps(value, ensure_ascii=True), flush=True)
    if args.obs_check:
        emit(installed())
        return 0
    if args.obs_send and not args.confirm_virtual_video:
        emit({"error": "未授权视频输出"})
        return 2
    camera = None
    gate = None
    try:
        gate = CoreGate(core_path(), time.monotonic_ns())
        camera = MemoryCamera() if args.memory_check else ObsCamera()
        emit({"ready": True, "memoryOnly": args.memory_check})
        consume(sys.stdin.buffer, camera, gate, emit)
        return 0
    except Exception as error:
        emit({"error": str(error)})
        return 1
    finally:
        if gate is not None:
            gate.stop()
        if camera is not None:
            camera.close()


if __name__ == "__main__":
    raise SystemExit(main())
