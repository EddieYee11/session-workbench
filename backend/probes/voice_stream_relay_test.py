#!/usr/bin/env python3
"""Exercise the Com! backend's /voice/stream relay the way the phone will.

Streams a wav as 16 kHz PCM at real time, prints every frame the relay pushes back,
then checks that a bad token and a bad capture id are refused.

usage: python voice_stream_relay_test.py <audio> [host:port]
"""
import asyncio
import json
import pathlib
import subprocess
import sys
import time
import uuid

import websockets

HOME = pathlib.Path.home()
TARGET = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:8650"
CHUNK = 3200  # 100 ms of 16 kHz s16le


def token():
    return (HOME / ".session-workbench" / "token").read_text().strip()


def pcm16(audio):
    return subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", audio,
                           "-ar", "16000", "-ac", "1", "-f", "s16le", "-"],
                          capture_output=True, check=True).stdout


async def stream(audio):
    pcm = pcm16(audio)
    capture = str(uuid.uuid4())
    url = "ws://%s/voice/stream/%s" % (TARGET, capture)
    print("audio %.1fs -> %s" % (len(pcm) / 32000, url))
    t0 = time.monotonic()
    seen = 0
    async with websockets.connect(url, additional_headers={"Authorization": "Bearer " + token()},
                                  max_size=None, open_timeout=10) as ws:
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


async def refused(path, header, label):
    try:
        async with websockets.connect("ws://%s%s" % (TARGET, path), additional_headers=header,
                                      open_timeout=10) as ws:
            await asyncio.wait_for(ws.recv(), 5)
        print("  %-22s ACCEPTED (should have been refused)" % label)
    except Exception as exc:
        print("  %-22s refused: %s" % (label, type(exc).__name__))


async def main():
    await stream(sys.argv[1])
    print("\nrejections:")
    good = {"Authorization": "Bearer " + token()}
    await refused("/voice/stream/%s" % uuid.uuid4(), {"Authorization": "Bearer wrong"}, "bad token")
    await refused("/voice/stream/not-a-capture-id", good, "bad capture id")
    await refused("/voice/stream/%s" % uuid.uuid4(), {}, "missing header")


asyncio.run(main())
