#!/usr/bin/env python3
"""Feed a wav into the ASR streaming endpoint and print incremental results.

usage: python ws_stream_test.py <wav> [ws_url] [realtime]
       realtime=1 (default) paces chunks at 100 ms of audio, like a phone would.
"""
import json
import subprocess
import sys
import time

from websockets.sync.client import connect

wav = sys.argv[1]
url = sys.argv[2] if len(sys.argv) > 2 else "ws://127.0.0.1:8646/stream"
realtime = (sys.argv[3] if len(sys.argv) > 3 else "1") == "1"

pcm = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                      "-ar", "16000", "-ac", "1", "-f", "s16le", "-"],
                     capture_output=True, check=True).stdout
CHUNK = 3200  # 100 ms
print("audio %.1fs -> %s" % (len(pcm) / 32000, url))

t0 = time.monotonic()
seen = []
with connect(url, max_size=None, open_timeout=10) as ws:
    for i in range(0, len(pcm), CHUNK):
        ws.send(pcm[i:i + CHUNK])
        if realtime:
            time.sleep(0.1)
        while True:  # drain anything already pushed back
            try:
                r = json.loads(ws.recv(timeout=0.02))
            except TimeoutError:
                break
            if r.get("type") == "partial":
                seen.append(r["text"])
                print("  +%.2fs partial: %s" % (time.monotonic() - t0, r["text"]))
    ws.send(json.dumps({"type": "end"}))
    while True:
        try:
            r = json.loads(ws.recv(timeout=20))
        except TimeoutError:
            print("  (timeout waiting for final)")
            break
        print("  +%.2fs %s: %s" % (time.monotonic() - t0, r.get("type"), r.get("text") or r.get("message")))
        if r.get("type") in ("final", "error"):
            break
print("total %.2fs, %d partials" % (time.monotonic() - t0, len(seen)))
