#!/usr/bin/env python3
"""Probe 火山方舟 Agent Plan 流式语音识别 (豆包 Seed-ASR 2.0).

目的:确认 Agent Plan 的专属 APIKey 能否直接调语音模型、走哪个端点、用什么鉴权。
只读探测,音频极短(约 2s),不写任何远端状态。

用法:  python volc_asr_probe.py [audio.wav]
"""
import asyncio
import gzip
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import uuid

import websockets

HOME = pathlib.Path.home()
RES = "volc.seedasr.sauc.duration"
EPS = [
    ("plan/async",    "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"),
    ("plan/nostream", "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream"),
]


def key_from(path):
    d = json.loads(pathlib.Path(path).read_text())
    for p in d.get("providers", []):
        if p.get("id") == "volcengine":
            return p["key"]
    raise SystemExit("no volcengine provider")


def variants(k):
    cid = str(uuid.uuid4())
    base = {"X-Api-Connect-Id": cid}
    return [
        ("appkey-only", {**base, "X-Api-App-Key": k}),
        ("appkey+res", {**base, "X-Api-App-Key": k, "X-Api-Resource-Id": RES}),
        ("appkey+bigasr", {**base, "X-Api-App-Key": k, "X-Api-Resource-Id": "volc.bigasr.sauc.duration"}),
        ("apikey-hdr", {**base, "X-Api-Key": k, "X-Api-Resource-Id": RES}),
        ("appkey+res-nocid", {"X-Api-App-Key": k, "X-Api-Resource-Id": RES}),
        ("bearer-res-nocid", {"Authorization": "Bearer " + k, "X-Api-Resource-Id": RES}),
    ]


def frame(mt, fl, ser, comp, payload, seq=None):
    b = bytes([0x11, (mt << 4) | fl, (ser << 4) | comp, 0x00])
    if seq is not None:
        b += struct.pack(">i", seq)
    return b + struct.pack(">I", len(payload)) + payload


def decode(data):
    if len(data) < 4:
        return {"raw": data[:80].hex()}
    hs = max(4, (data[0] & 0x0F) * 4)
    mt, fl = (data[1] >> 4) & 0x0F, data[1] & 0x0F
    comp = data[2] & 0x0F
    cur = hs
    out = {"mt": mt, "fl": fl, "hs": hs}
    if fl & 0x1 and len(data) >= cur + 4:
        out["seq"] = struct.unpack(">i", data[cur:cur + 4])[0]
        cur += 4
    if fl & 0x4 and len(data) >= cur + 4:
        out["event"] = struct.unpack(">i", data[cur:cur + 4])[0]
        cur += 4
    if mt == 0xF and len(data) >= cur + 4:
        out["code"] = struct.unpack(">i", data[cur:cur + 4])[0]
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
    out["text"] = payload[:500].decode("utf8", "replace")
    return out


def pcm_from(wav):
    with tempfile.NamedTemporaryFile(suffix=".pcm", delete=False) as f:
        raw = f.name
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-ar", "16000",
                    "-ac", "1", "-f", "s16le", raw], check=True)
    return pathlib.Path(raw).read_bytes()


async def attempt(ep_name, url, vname, headers, pcm):
    print("\n===== %s / %s =====" % (ep_name, vname), flush=True)
    try:
        async with websockets.connect(url, additional_headers=headers, max_size=None,
                                      open_timeout=20, ping_interval=None) as ws:
            print("  handshake OK", flush=True)
            cfg = {"user": {"uid": "com-probe"},
                   "audio": {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
                   "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True,
                               "result_type": "full"}}
            await ws.send(frame(0x1, 0x1, 0x1, 0x0, json.dumps(cfg).encode(), seq=1))
            try:
                print("  cfg ->", decode(await asyncio.wait_for(ws.recv(), 10)), flush=True)
            except asyncio.TimeoutError:
                print("  cfg -> TIMEOUT", flush=True)
            seq, step, texts = 2, 3200, []
            for i in range(0, len(pcm), step):
                chunk = pcm[i:i + step]
                last = i + step >= len(pcm)
                await ws.send(frame(0x2, 0x3 if last else 0x1, 0x0, 0x0, chunk,
                                    seq=-seq if last else seq))
                seq += 1
                await asyncio.sleep(0.04)
            while True:
                try:
                    r = decode(await asyncio.wait_for(ws.recv(), 12))
                except asyncio.TimeoutError:
                    print("  recv TIMEOUT", flush=True)
                    break
                print("  <-", r, flush=True)
                try:
                    t = json.loads(r.get("text") or "{}").get("result", {}).get("text")
                    if t:
                        texts.append(t)
                except Exception:
                    pass
                if r.get("mt") == 0xF or (r.get("fl", 0) & 0x2):
                    break
            print("  TRANSCRIPT:", (" | ".join(texts) or "<empty>")[:300], flush=True)
            return True
    except Exception as e:
        r = getattr(e, "response", None)
        extra = ""
        if r is not None:
            try:
                body = getattr(r, "body", b"") or b""
                extra = " status=%s body=%r" % (r.status_code, body[:400])
            except Exception as ex:
                extra = " (body unreadable: %s)" % ex
        print("  FAILED %s%s" % (type(e).__name__, extra), flush=True)
        return False


async def main():
    wav = sys.argv[1] if len(sys.argv) > 1 else str(HOME / ".pi-gateway/asr/samples/short.wav")
    key = key_from(HOME / ".config/magpie/providers.json")
    pcm = pcm_from(wav)
    print("audio=%s pcm=%dB (%.1fs) key=%s...%s len=%d"
          % (pathlib.Path(wav).name, len(pcm), len(pcm) / 32000, key[:6], key[-4:], len(key)), flush=True)
    for ep_name, url in EPS:
        for vname, headers in variants(key):
            if await attempt(ep_name, url, vname, headers, pcm):
                print("\n>>> WORKING: %s / %s" % (ep_name, vname), flush=True)
                return
    print("\n>>> none worked", flush=True)


asyncio.run(main())
