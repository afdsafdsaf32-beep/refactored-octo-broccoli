"""
PhoneVR PC server.

Captures the desktop, encodes it as H.264 (via ffmpeg) and streams it over a
plain TCP socket. Listens on a second TCP socket for head-orientation packets
sent by the iPhone client and turns yaw/pitch deltas into relative mouse
movement, so any game with mouse-look can be steered by turning your head.

Works identically whether the iPhone is reached over Wi-Fi (connect directly
to this machine's LAN IP) or over USB (see docs/usb-tunnel.md - you forward
these same two TCP ports through usbmuxd/iproxy, so the code below needs no
knowledge of which transport is being used).

Requires: ffmpeg.exe on PATH, `pip install mss`.
"""

import ctypes
import json
import socket
import struct
import subprocess
import threading
import time

VIDEO_PORT = 9001
CONTROL_PORT = 9002

CAPTURE_W, CAPTURE_H, FPS = 1280, 720, 60
MOUSE_SENSITIVITY = 8.0  # degrees -> pixels scaling, tune per game


def start_ffmpeg_encoder():
    """Reads raw BGRA frames on stdin, writes an H.264 Annex-B stream on stdout."""
    cmd = [
        "ffmpeg", "-loglevel", "error",
        "-f", "rawvideo", "-pixel_format", "bgra",
        "-video_size", f"{CAPTURE_W}x{CAPTURE_H}", "-framerate", str(FPS),
        "-i", "-",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-x264-params", "keyint=60:scenecut=0",
        "-f", "h264", "-",
    ]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def video_server():
    import mss

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", VIDEO_PORT))
    srv.listen(1)
    print(f"[video] listening on {VIDEO_PORT}")

    while True:
        conn, addr = srv.accept()
        print(f"[video] client connected from {addr}")
        ffmpeg = start_ffmpeg_encoder()

        stop = threading.Event()

        def pump_encoded_to_socket():
            try:
                while not stop.is_set():
                    chunk = ffmpeg.stdout.read(4096)
                    if not chunk:
                        break
                    conn.sendall(chunk)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                stop.set()

        sender = threading.Thread(target=pump_encoded_to_socket, daemon=True)
        sender.start()

        frame_interval = 1.0 / FPS
        try:
            with mss.mss() as sct:
                monitor = sct.monitors[1]
                region = {
                    "left": monitor["left"], "top": monitor["top"],
                    "width": CAPTURE_W, "height": CAPTURE_H,
                }
                while not stop.is_set():
                    t0 = time.time()
                    frame = sct.grab(region)
                    try:
                        ffmpeg.stdin.write(frame.bgra)
                    except (BrokenPipeError, OSError):
                        break
                    dt = time.time() - t0
                    if dt < frame_interval:
                        time.sleep(frame_interval - dt)
        finally:
            stop.set()
            try:
                ffmpeg.stdin.close()
            except OSError:
                pass
            ffmpeg.terminate()
            conn.close()
            print("[video] client disconnected")


# --- head tracking -> mouse look -------------------------------------------

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long),
                ("mouseData", ctypes.c_ulong), ("dwFlags", ctypes.c_ulong),
                ("time", ctypes.c_ulong), ("dwExtraInfo", ctypes.c_void_p)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ulong), ("mi", MOUSEINPUT)]


INPUT_MOUSE = 0
MOUSEEVENTF_MOVE = 0x0001


def send_relative_mouse_move(dx: int, dy: int):
    inp = INPUT(type=INPUT_MOUSE, mi=MOUSEINPUT(dx, dy, 0, MOUSEEVENTF_MOVE, 0, None))
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(inp))


def control_server():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", CONTROL_PORT))
    srv.listen(1)
    print(f"[control] listening on {CONTROL_PORT}")

    while True:
        conn, addr = srv.accept()
        print(f"[control] client connected from {addr}")
        last_yaw = last_pitch = None
        buf = b""
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                buf += data
                # length-prefixed JSON: 4-byte big-endian length + payload
                while len(buf) >= 4:
                    (length,) = struct.unpack(">I", buf[:4])
                    if len(buf) < 4 + length:
                        break
                    payload, buf = buf[4:4 + length], buf[4 + length:]
                    msg = json.loads(payload.decode("utf-8"))
                    yaw, pitch = msg["yaw"], msg["pitch"]
                    if last_yaw is not None:
                        dyaw = (yaw - last_yaw) * MOUSE_SENSITIVITY
                        dpitch = (pitch - last_pitch) * MOUSE_SENSITIVITY
                        send_relative_mouse_move(int(dyaw), int(-dpitch))
                    last_yaw, last_pitch = yaw, pitch
        except ConnectionResetError:
            pass
        finally:
            conn.close()
            print("[control] client disconnected")


if __name__ == "__main__":
    threading.Thread(target=video_server, daemon=True).start()
    threading.Thread(target=control_server, daemon=True).start()
    print("PhoneVR server running. Ctrl+C to stop.")
    while True:
        time.sleep(1)
