#!/usr/bin/env python3
"""Same as voice_stream_relay_test.py, but through the public Caddy path the phone uses.

Proves the /sessions prefix forwards the WebSocket upgrade to the Com! backend.

usage: python voice_stream_proxy_test.py <audio> [wss://host:port/sessions]
"""
import asyncio
import json
import pathlib
import subprocess
import sys
import time
import uuid
from urllib.parse import urlsplit

import websockets

HOME = pathlib.Path.home()
BASE = sys.argv[2] if len(sys.argv) > 2 else "wss://pi.eddiegao.work:8443/sessions"
CHUNK = 3200  # 100 ms of 16 kHz s16le


def token():
    return (HOME / ".session-workbench" / "token").read_text().strip()


def pcm16(audio):
    return subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", audio,
                           "-ar", "16000", "-ac", "1", "-f", "s16le", "-"],
                          capture_output=True, check=True).stdout


async def refused(url, header, label):
    try:
        async with websockets.connect(url, additional_headers=header, open_timeout=15) as ws:
            await asyncio.wait_for(ws.recv(), 5)
        print("  %-22s ACCEPTED (should have been refused)" % label)
    except Exception as exc:
        print("  %-22s refused: %s" % (label, type(exc).__name__))


async def main():
    pcm = pcm16(sys.argv[1])
    capture = str(uuid.uuid4())
    url = BASE.rstrip("/") + "/voice/stream/" + capture
    host = urlsplit(BASE).hostname
    print("audio %.1fs -> %s" % (len(pcm) / 32000, url))
    t0 = time.monotonic()
    seen = 0
    async with websockets.connect(url, additional_headers={"Authorization": "Bearer " + token()},
                                  max_size=None, open_timeout=15) as ws:
        print("  +%.2fs upgraded through the proxy" % (time.monotonic() - t0))

        async def drain():
            nonlocal seen
            async for frame in ws:
                event = json.loads(frame)
                seen += 1
                label = event.get("type")
                body = event.get("text") or event.get("message")
                print("  +%.2fs %-8s %s" % (time.monotonic() - t0, label, body))
                if label in ("final", "error"):
                    return
        reader = asyncio.create_task(drain())
        for index in range(0, len(pcm), CHUNK):
            await ws.send(pcm[index:index + CHUNK])
            await asyncio.sleep(0.1)
        await ws.send(json.dumps({"type": "end"}))
        try:
            await asyncio.wait_for(reader, 60)
        except asyncio.TimeoutError:
            print("  (no final within 60s)")
    print("total %.2fs, %d frames" % (time.monotonic() - t0, seen))

    print("\nrejections over the proxy (%s):" % host)
    good = {"Authorization": "Bearer " + token()}
    root = BASE.rstrip("/") + "/voice/stream/"
    await refused(root + str(uuid.uuid4()), {"Authorization": "Bearer wrong"}, "bad token")
    await refused(root + "not-a-capture-id", good, "bad capture id")
    await refused(root + str(uuid.uuid4()), {}, "missing header")


asyncio.run(main())
