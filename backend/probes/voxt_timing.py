#!/usr/bin/env python3
"""Where does 豆包 whole-file time actually go? Handshake / feed / tail, per endpoint.

Imports the live server module as a library (its __main__ guard keeps the HTTP and
WS servers from starting) so this measures the shipped code, not a copy of it.

usage: python voxt_timing.py <audio> [endpoint ...]
"""
import importlib.util
import os
import subprocess
import sys
import time

ASR_DIR = os.path.expanduser("~/.pi-gateway/asr")


def load_server():
    spec = importlib.util.spec_from_file_location("asr_server", os.path.join(ASR_DIR, "asr_server.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def pcm16(path):
    return subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path,
                           "-ar", "16000", "-ac", "1", "-f", "s16le", "-"],
                          capture_output=True, check=True).stdout


def run(mod, url, pcm, pace):
    mod.DOUBAO_URL = url
    t0 = time.monotonic()
    s = mod.DoubaoSession()
    t_hand = time.monotonic() - t0
    mod.DOUBAO_PACE = pace
    t1 = time.monotonic()
    s.push(pcm, pace=pace)
    t_feed = time.monotonic() - t1
    t2 = time.monotonic()
    text = s.finish().strip()
    t_tail = time.monotonic() - t2
    s.close()
    return text, t_hand, t_feed, t_tail, time.monotonic() - t0


if __name__ == "__main__":
    audio = sys.argv[1]
    eps = sys.argv[2:] or ["bigmodel_async", "bigmodel_nostream"]
    mod = load_server()
    pcm = pcm16(audio)
    dur = len(pcm) / 32000
    print("audio %.1fs  (pace %.2f = %.0fx realtime)\n" % (dur, mod.DOUBAO_PACE, 0.1 / mod.DOUBAO_PACE))
    for ep in eps:
        url = "wss://openspeech.bytedance.com/api/v3/plan/sauc/" + ep
        try:
            text, h, f, t, tot = run(mod, url, pcm, mod.DOUBAO_PACE)
        except Exception as exc:
            print("%-20s FAILED %s: %s" % (ep, type(exc).__name__, str(exc)[:120]))
            continue
        print("%-20s total %5.2fs = handshake %4.2f + feed %5.2f + tail %5.2f   (x%.1f audio)"
              % (ep, tot, h, f, t, tot / dur))
        print("   %s\n" % text[:120])
