#!/usr/bin/env python3
"""A/B: 本地 Qwen3-ASR (127.0.0.1:8647) vs 火山 Agent Plan 豆包流式 ASR.

用 Eddie 真实用语风格的记账/操作短句做语料(macOS say -v Tingting 合成),
逐句跑两个引擎,打印转写结果与延迟对照表。

注意: 合成语音不是真实口音,这是当前可得的最好代理;结论需按此保留。
用法: python volc_asr_ab.py [--keep]
"""
import asyncio
import gzip
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import time
import uuid

import httpx
import websockets

HOME = pathlib.Path.home()
WORK = HOME / "voxt-asr-probe"
CORPUS = WORK / "corpus"
LOCAL = "http://127.0.0.1:8647/transcribe"
URL = "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"
RES = "volc.seedasr.sauc.duration"

SENTENCES = [
    "加油花费九十六块七毛七。",
    "买手机支架花费两百八十一。",
    "上网话费九十块九。",
    "早饭花费六块四。",
    "买零食花费四十六块六毛四。",
    "把小米十八Pro卖了，挣了九千九。",
    "帮我记一下，今天早上要发一个顺丰的快递，快递取件码是二七五。",
    "午饭花费二十六块七。",
    "购买VR游戏花费四十元人民币。",
    "时间改成八点三十分，我设定一个强提醒。",
    "骑共享单车花费一块八毛八。",
    "打印材料花费三块钱。",
    "加油花费二百一十八块四毛七。",
    "买饮料花费七块五。",
    "把一点零六往后的三笔记账全都删了，包括一点零六的这一笔。",
]


def make_corpus():
    CORPUS.mkdir(parents=True, exist_ok=True)
    files = []
    for i, text in enumerate(SENTENCES):
        wav = CORPUS / ("%02d.wav" % i)
        if not wav.exists():
            aiff = CORPUS / ("%02d.aiff" % i)
            subprocess.run(["say", "-v", "Tingting", "-o", str(aiff), text], check=True)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff),
                            "-ar", "16000", "-ac", "1", str(wav)], check=True)
            aiff.unlink(missing_ok=True)
        files.append((i, text, wav))
    return files


def key():
    d = json.loads((HOME / ".config/magpie/providers.json").read_text())
    for p in d.get("providers", []):
        if p.get("id") == "volcengine":
            return p["key"]
    raise SystemExit("no volcengine provider")


def frame(mt, fl, ser, comp, payload, seq=None):
    b = bytes([0x11, (mt << 4) | fl, (ser << 4) | comp, 0x00])
    if seq is not None:
        b += struct.pack(">i", seq)
    return b + struct.pack(">I", len(payload)) + payload


def decode(data):
    if len(data) < 4:
        return None
    hs = max(4, (data[0] & 0x0F) * 4)
    mt, fl, comp = (data[1] >> 4) & 0x0F, data[1] & 0x0F, data[2] & 0x0F
    cur = hs
    out = {"mt": mt, "fl": fl}
    if fl & 0x1 and len(data) >= cur + 4:
        out["seq"] = struct.unpack(">i", data[cur:cur + 4])[0]
        cur += 4
    if fl & 0x4 and len(data) >= cur + 4:
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
        return out
    if comp == 0x1:
        try:
            payload = gzip.decompress(payload)
        except Exception:
            pass
    out["text"] = payload.decode("utf8", "replace")
    return out


def local_transcribe(wav):
    t = time.monotonic()
    r = httpx.post(LOCAL, content=wav.read_bytes(),
                   headers={"Content-Type": "audio/wav"}, timeout=120, trust_env=False)
    r.raise_for_status()
    d = r.json()
    return d.get("text", ""), time.monotonic() - t, d.get("asr_s")


async def doubao_transcribe(wav, k):
    pcm = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav),
                          "-ar", "16000", "-ac", "1", "-f", "s16le", "-"],
                         capture_output=True, check=True).stdout
    headers = {"X-Api-Key": k, "X-Api-Resource-Id": RES, "X-Api-Connect-Id": str(uuid.uuid4())}
    t0 = time.monotonic()
    first_at, final_text = None, ""
    async with websockets.connect(URL, additional_headers=headers, max_size=None,
                                  open_timeout=20, ping_interval=None) as ws:
        cfg = {"user": {"uid": "com-ab"},
               "audio": {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
               "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True,
                           "result_type": "full"}}
        await ws.send(frame(0x1, 0x1, 0x1, 0x0, json.dumps(cfg).encode(), seq=1))
        await ws.recv()
        seq, step = 2, 3200
        for i in range(0, len(pcm), step):
            chunk = pcm[i:i + step]
            last = i + step >= len(pcm)
            await ws.send(frame(0x2, 0x3 if last else 0x1, 0x0, 0x0, chunk,
                                seq=-seq if last else seq))
            seq += 1
            if not last:
                await asyncio.sleep(0.02)
        while True:
            try:
                r = decode(await asyncio.wait_for(ws.recv(), 15))
            except asyncio.TimeoutError:
                break
            if not r:
                continue
            try:
                txt = json.loads(r.get("text") or "{}").get("result", {}).get("text") or ""
            except Exception:
                txt = ""
            if txt:
                if first_at is None:
                    first_at = time.monotonic() - t0
                final_text = txt
            if r.get("mt") == 0xF or (r.get("fl", 0) & 0x2):
                break
    end = time.monotonic() - t0
    return final_text, (first_at if first_at else end), end


def norm(s):
    return (s or "").replace(" ", "").replace("，", ",").replace("。", "").strip()


async def main():
    k = key()
    files = make_corpus()
    try:
        await doubao_transcribe(files[0][2], k)  # warm handshake
    except Exception as e:
        print("warmup failed:", e)
    print("%-30s | %-34s | %-34s" % ("原句(TTS)", "本地 Qwen3-ASR-0.6B", "豆包 Seed-ASR 2.0"))
    print("-" * 106)
    rows = []
    for i, text, wav in files:
        try:
            lt, ltot, _ = local_transcribe(wav)
        except Exception as e:
            lt, ltot = "<ERR %s>" % type(e).__name__, 0
        try:
            dt, dfirst, dtot = await doubao_transcribe(wav, k)
        except Exception as e:
            dt, dfirst, dtot = "<ERR %s: %s>" % (type(e).__name__, str(e)[:40]), 0, 0
        lok = "OK " if norm(lt) == norm(text) else "XX "
        dok = "OK " if norm(dt) == norm(text) else "XX "
        print("%-30s | %s%-28s %.2fs | %s%-28s %.2fs(首%.2fs)"
              % (text[:28], lok, lt[:28], ltot, dok, dt[:28], dtot, dfirst))
        rows.append((text, lt, dt, ltot, dtot, dfirst))
    print("-" * 106)
    lok = sum(1 for t, lt, _, _, _, _ in rows if norm(lt) == norm(t))
    dok = sum(1 for t, _, dt, _, _, _ in rows if norm(dt) == norm(t))
    print("完全一致: 本地 %d/%d   豆包 %d/%d" % (lok, len(rows), dok, len(rows)))
    print("平均总延迟: 本地 %.2fs   豆包 %.2fs (豆包首字 %.2fs)"
          % (sum(r[3] for r in rows) / len(rows), sum(r[4] for r in rows) / len(rows),
             sum(r[5] for r in rows) / len(rows)))


asyncio.run(main())
