#!/usr/bin/env python3
"""Find the fastest chunk pacing that still yields clean 豆包 output.

Feeds the same clip at several paces and prints the transcript, so the whole-file
/transcribe path can be sped up without degrading into per-packet fragments.
"""
import gzip
import json
import pathlib
import struct
import subprocess
import sys
import time
import uuid

from websockets.sync.client import connect

HOME = pathlib.Path.home()
URL = "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"
RES = "volc.seedasr.sauc.duration"
CHUNK = 3200  # 100 ms of 16 kHz s16le


def key():
    d = json.loads((HOME / ".config/magpie/providers.json").read_text())
    return next(p["key"] for p in d["providers"] if p.get("id") == "volcengine")


def frame(mt, fl, ser, comp, payload, seq=None):
    b = bytes([0x11, (mt << 4) | fl, (ser << 4) | comp, 0x00])
    if seq is not None:
        b += struct.pack(">i", seq)
    return b + struct.pack(">I", len(payload)) + payload


def decode(data):
    """-> (json_body, is_final)."""
    hs = max(4, (data[0] & 0x0F) * 4)
    mt, fl, comp = (data[1] >> 4) & 0x0F, data[1] & 0x0F, data[2] & 0x0F
    cur = hs
    if fl & 0x1 and len(data) >= cur + 4:
        cur += 4
    if fl & 0x4 and len(data) >= cur + 4:
        cur += 4
    if mt == 0xF and len(data) >= cur + 4:
        cur += 4
    if mt == 0xB:
        payload = data[cur:]
    elif len(data) >= cur + 4:
        size = struct.unpack(">I", data[cur:cur + 4])[0]
        cur += 4
        payload = data[cur:cur + size]
    else:
        payload = b""
    if comp == 0x1:
        try:
            payload = gzip.decompress(payload)
        except Exception:
            pass
    try:
        return json.loads(payload.decode("utf8", "replace")), bool(fl & 0x2)
    except Exception:
        return {}, bool(fl & 0x2)


def run(pcm, pace):
    headers = {"X-Api-Key": key(), "X-Api-Resource-Id": RES,
               "X-Api-Connect-Id": str(uuid.uuid4())}
    t0 = time.monotonic()
    ws = connect(URL, additional_headers=headers, max_size=None, open_timeout=15, legacy=True)
    try:
        cfg = {"user": {"uid": "pace"},
               "audio": {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
               "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True,
                           "result_type": "full"}}
        ws.send(frame(0x1, 0x1, 0x1, 0x0, json.dumps(cfg).encode(), seq=1))
        ws.recv(timeout=10)
        seq = 2
        for i in range(0, len(pcm), CHUNK):
            ws.send(frame(0x2, 0x1, 0x0, 0x0, pcm[i:i + CHUNK], seq=seq))
            seq += 1
            if pace:
                time.sleep(pace)
        ws.send(frame(0x2, 0x3, 0x0, 0x0, b"", seq=-seq))
        text, deadline = "", time.monotonic() + 30
        while time.monotonic() < deadline:
            body, final = decode(ws.recv(timeout=10))
            t = (body.get("result") or {}).get("text") or ""
            if t:
                text = t
            if final:
                break
        return text, time.monotonic() - t0
    finally:
        try:
            ws.close()
        except Exception:
            pass


if __name__ == "__main__":
    src = sys.argv[1]
    pcm = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-ar", "16000",
                          "-ac", "1", "-f", "s16le", "-"], capture_output=True, check=True).stdout
    print("audio %.1fs" % (len(pcm) / 32000))
    for pace in (0, 0.01, 0.02, 0.05):
        txt, dt = run(pcm, pace)
        label = "blast" if pace == 0 else "%.2fs/100ms = %.0fx realtime" % (pace, 0.1 / pace)
        print("\n--- pace %s | total %.2fs ---\n%s" % (label, dt, txt))
