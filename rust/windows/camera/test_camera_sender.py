"""只用内存管道与假摄像头验证协议、迟到帧、停止和超时；不触发设备 I/O。"""
import io
import importlib.util
import os
import types
import threading
import unittest
from unittest.mock import patch

import camera_sender as sender


class Gate:
    def __init__(self):
        self.sequence = 0
        self.stopped = False

    def accept(self, sequence, age, now):
        if sequence <= self.sequence or age > sender.MAX_AGE_NS:
            return False
        self.sequence = sequence
        return True

    def stop(self):
        self.stopped = True


class Camera:
    def __init__(self):
        self.frames = 0

    def send(self, data):
        self.frames += 1


def packet(sequence=1, age=0, size=sender.FRAME_BYTES, magic=b"CBV1"):
    return sender.HEADER.pack(magic, size, sequence, age) + bytes(sender.FRAME_BYTES)


class Tests(unittest.TestCase):
    def test_clean_eof_stops_without_frame(self):
        gate, camera = Gate(), Camera()
        sender.consume(io.BytesIO(), camera, gate, lambda _: None)
        self.assertTrue(gate.stopped)
        self.assertEqual(camera.frames, 0)

    def test_complete_frame_acknowledged_then_stops(self):
        gate, camera, responses = Gate(), Camera(), []
        sender.consume(io.BytesIO(packet()), camera, gate, responses.append)
        self.assertEqual(responses, [{"sequence": 1, "accepted": True}])
        self.assertEqual(camera.frames, 1)
        self.assertTrue(gate.stopped)

    def test_bad_headers_rejected_before_payload_read(self):
        for data in [packet(size=2**32-1), packet(magic=b"FAKE"), packet(sequence=0), packet(age=sender.MAX_AGE_NS+1)]:
            with self.subTest(header=data[:24]), self.assertRaises(ValueError):
                sender.read_packet(io.BytesIO(data[:24]))

    def test_truncated_header_and_payload(self):
        for size in [1, 23, 24, 1000]:
            with self.subTest(size=size), self.assertRaises(ValueError):
                sender.read_packet(io.BytesIO(packet()[:size]))

    def test_duplicate_frame_never_sent(self):
        gate, camera = Gate(), Camera()
        with self.assertRaises(ValueError):
            sender.consume(io.BytesIO(packet()+packet()), camera, gate, lambda _: None)
        self.assertEqual(camera.frames, 1)
        self.assertTrue(gate.stopped)

    def test_pipe_time_counts_towards_age(self):
        gate, camera = Gate(), Camera()
        values = iter([1, sender.MAX_AGE_NS+2])
        with self.assertRaises(ValueError):
            sender.consume(io.BytesIO(packet()), camera, gate, lambda _: None, clock=lambda: next(values))
        self.assertEqual(camera.frames, 0)
        self.assertTrue(gate.stopped)

    def test_blocked_partial_pipe_times_out(self):
        released = threading.Event()
        class Blocked:
            def read(self, size):
                released.wait(1)
                return b""
        gate = Gate()
        try:
            with self.assertRaises(TimeoutError):
                sender.consume(Blocked(), Camera(), gate, lambda _: None, timeout=.03)
            self.assertTrue(gate.stopped)
        finally:
            released.set()

    def test_no_device_creation_without_authorization(self):
        with patch.object(sender, "ObsCamera", side_effect=AssertionError("must not create")):
            with patch("builtins.print"):
                self.assertEqual(sender.main(["--obs-send"]), 2)


@unittest.skipUnless(importlib.util.find_spec("numpy"), "numpy required for OBS pixel conversion")
class ObsPixelConversion(unittest.TestCase):
    def test_final_rgba_becomes_contiguous_rgb_without_channel_swap(self):
        import numpy as np
        # 假设备仅验证真实 NumPy 转换，不打开摄像头；RGBA 初始化会立即失败。
        class Backend:
            def __init__(self, width, height, fps, *, fmt, device, backend):
                assert (width, height, fps, fmt, device, backend) == (
                    sender.WIDTH, sender.HEIGHT, 30, "RGB", "OBS Virtual Camera", "obs")
                self.frames = []
                self.closed = False
            def send(self, frame):
                assert frame.flags.c_contiguous and frame.dtype == np.uint8
                self.frames.append(frame.copy())
            def close(self):
                self.closed = True
        module = types.SimpleNamespace(Camera=Backend, PixelFormat=types.SimpleNamespace(RGB="RGB"))
        with patch.dict("sys.modules", {"pyvirtualcam": module}):
            camera = sender.ObsCamera()
        rgba = np.zeros((sender.HEIGHT, sender.WIDTH, 4), dtype=np.uint8)
        rgba[:] = [12, 34, 56, 255]
        rgba[0, 1] = [250, 100, 25, 255]
        camera.send(rgba.tobytes())
        np.testing.assert_array_equal(camera.camera.frames[0], rgba[:, :, :3])
        rgba[:] = [90, 80, 70, 255]
        camera.send(rgba.tobytes())
        np.testing.assert_array_equal(camera.camera.frames[1], rgba[:, :, :3])
        with self.assertRaises(ValueError):
            camera.send(b"truncated")
        self.assertEqual(len(camera.camera.frames), 2)
        camera.close()
        self.assertTrue(camera.camera.closed)


@unittest.skipUnless(os.environ.get("CB_TEST_CORE"), "set CB_TEST_CORE to load the actual Rust library")
class CoreIntegration(unittest.TestCase):
    def test_actual_rust_layout_expiry_replay_and_stop(self):
        gate = sender.CoreGate(os.environ["CB_TEST_CORE"], 1)
        self.assertEqual(sender.ctypes.sizeof(sender.VideoGate), 40)
        self.assertTrue(gate.accept(1, 0, 2))
        self.assertFalse(gate.accept(1, 0, 3))
        self.assertFalse(gate.accept(2, sender.MAX_AGE_NS + 1, sender.MAX_AGE_NS + 10))
        self.assertTrue(gate.accept(2, 0, 4))
        gate.stop()
        self.assertFalse(gate.accept(3, 0, 5))


if __name__ == "__main__":
    unittest.main()
