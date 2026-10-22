#!/usr/bin/env python3
"""Resident ASR service for the iPhone voice channel and Com!.

Engine order: 豆包 Seed-ASR 2.0 (火山方舟 Agent Plan, 流式) -> 本地 Qwen3-ASR (MLX) 兜底.
本地模型常驻内存,豆包不可用(断网/额度/鉴权失败)时自动回落,不丢录音。

HTTP (127.0.0.1:8647)
  POST /transcribe  raw audio, any ffmpeg-readable format, or multipart
                    -> {"text": "...", "engine": "doubao|local", "asr_s": .., "audio_s": ..}
  GET  /health      -> "ok" once warmed

WS (127.0.0.1:8646)
  /stream           client sends binary PCM s16le / 16 kHz / mono frames,
                    then a text frame {"type":"end"} (or just closes).
                    server pushes {"type":"partial"|"final","text":..,"definite":bool}
                    and on failure {"type":"error","message":..} after any partials.
"""
import gzip
import json
import os
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = os.environ.get("ASR_REPO", "mlx-community/Qwen3-ASR-0.6B-8bit")
PORT = int(os.environ.get("ASR_PORT", "8647"))
WS_PORT = int(os.environ.get("ASR_WS_PORT", "8646"))  # 8648 belongs to the pi-gateway dashboard
FFMPEG = "/opt/homebrew/bin/ffmpeg"
MAX_BODY = 16 * 1024 * 1024
HERE = Path(__file__).resolve().parent
KEY_FILE = Path(os.environ.get(
    "ASR_DOUBAO_KEY_FILE",
    str(HERE / "volc.json") if (HERE / "volc.json").exists()
    else str(Path.home() / ".pi-gateway" / "asr" / "volc.json")))

DOUBAO_URL = os.environ.get(
    "ASR_DOUBAO_URL",
    "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async")
DOUBAO_RESOURCE = os.environ.get("ASR_DOUBAO_RESOURCE", "volc.seedasr.sauc.duration")
DOUBAO_ENABLED = os.environ.get("ASR_DOUBAO", "1") != "0"
DOUBAO_CONFIG = {
    "user": {"uid": "pi-asr"},
    "audio": {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
    "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True,
                "result_type": "full"},
}
CHUNK = 3200  # 100 ms of 16 kHz s16le
# 豆包 is a streaming model: feeding it faster than this makes it emit per-packet
# fragments ("花。了3。10。5。块钱") instead of merged utterances. Measured on a 14 s
# clip: blast/10x/5x fragment, 2x is clean. The /stream path doesn't need this —
# the phone paces it naturally.
DOUBAO_PACE = float(os.environ.get("ASR_DOUBAO_PACE", "0.05"))
DOUBAO_WHOLEFILE = os.environ.get("ASR_DOUBAO_WHOLEFILE", "1") != "0"

from mlx_audio.stt.utils import load  # noqa: E402

t0 = time.monotonic()
MODEL = load(REPO)
LOCK = threading.Lock()  # one Metal decode at a time
print("model %s loaded %.2fs" % (REPO, time.monotonic() - t0), flush=True)


# ---------------------------------------------------------------- 豆包 protocol

def _key():
    try:
        return json.loads(KEY_FILE.read_text())["api_key"].strip()
    except Exception:
        return ""


def _frame(mt, fl, ser, comp, payload, seq=None):
    b = bytes([0x11, (mt << 4) | fl, (ser << 4) | comp, 0x00])
    if seq is not None:
        b += struct.pack(">i", seq)
    return b + struct.pack(">I", len(payload)) + payload


def _decode(data):
    """Server -> {mt, fl, text, code}. Mirrors the framing we send."""
    if len(data) < 4:
        return None
    hs = max(4, (data[0] & 0x0F) * 4)
    mt, fl, comp = (data[1] >> 4) & 0x0F, data[1] & 0x0F, data[2] & 0x0F
    cur = hs
    if fl & 0x1 and len(data) >= cur + 4:
        cur += 4
    if fl & 0x4 and len(data) >= cur + 4:
        cur += 4
    out = {"mt": mt, "fl": fl, "code": None, "text": ""}
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


def _result_text(raw):
    try:
        return (json.loads(raw).get("result", {}) or {}).get("text") or ""
    except Exception:
        return ""


class DoubaoSession:
    """One 豆包 streaming session. Feed PCM, read partial transcripts."""

    def __init__(self, timeout=25):
        from websockets.sync.client import connect
        headers = {"X-Api-Key": _key(), "X-Api-Resource-Id": DOUBAO_RESOURCE,
                   "X-Api-Connect-Id": str(uuid.uuid4())}
        # legacy=True: the connection outlives this call, so it can't be a context manager.
        self.ws = connect(DOUBAO_URL, additional_headers=headers, max_size=None,
                          open_timeout=10, close_timeout=5, legacy=True)
        self.ws.send(_frame(0x1, 0x1, 0x1, 0x0, json.dumps(DOUBAO_CONFIG).encode(), seq=1))
        self.ws.recv(timeout=timeout)
        self.seq = 2
        self.last = ""
        self.pending = bytearray()
        self.timeout = timeout
        self.done = False  # server already sent its final response
        self.sleep_s = 0.0  # debug: time spent pacing
        self.drain_s = 0.0  # debug: time spent reading replies

    def push(self, pcm, pace=0.0):
        """Buffer PCM and forward whole chunks; keep one chunk back for the final packet.
        pace sleeps per 100 ms chunk — see DOUBAO_PACE.

        Drains every chunk, not just at the end: feeding a whole 14 s file without
        reading leaves the server's replies queued, and the backlog showed up as
        ~17 s of tail latency in finish()."""
        self.pending.extend(pcm)
        while len(self.pending) >= 2 * CHUNK:
            chunk = bytes(self.pending[:CHUNK])
            del self.pending[:CHUNK]
            self.ws.send(_frame(0x2, 0x1, 0x0, 0x0, chunk, seq=self.seq))
            self.seq += 1
            if pace:
                t = time.monotonic()
                time.sleep(pace)
                self.sleep_s += time.monotonic() - t
            t = time.monotonic()
            self._drain()
            self.drain_s += time.monotonic() - t
        return self.last

    def _send_last(self):
        """Final audio packet: negative sequence when it carries audio, else flag 2."""
        if self.pending:
            self.ws.send(_frame(0x2, 0x3, 0x0, 0x0, bytes(self.pending), seq=-self.seq))
            self.pending.clear()
        else:
            self.ws.send(_frame(0x2, 0x2, 0x0, 0x0, b""))

    def _drain(self):
        """Read only what is already buffered. Must not block: the caller is holding
        the phone's audio loop, and every millisecond spent waiting here is added to
        the round trip. Anything arriving late is picked up on the next chunk.
        Bounded so a chatty server can never starve the feed loop."""
        for _ in range(8):
            try:
                r = _decode(self.ws.recv(timeout=0.005))
            except TimeoutError:
                break
            except Exception:
                break
            if not r:
                continue
            if r["code"]:
                raise RuntimeError("doubao error %s: %s" % (r["code"], r["text"][:200]))
            txt = _result_text(r.get("text") or "")
            if txt:
                self.last = txt
            # final response: last-packet flag on the server frame
            if r["fl"] & 0x2:
                self.done = True
                break
        return self.last

    def finish(self):
        """Flush the tail, signal end of audio, collect until the final result."""
        if self.done:
            return self.last
        deadline = time.monotonic() + self.timeout
        self._send_last()
        while time.monotonic() < deadline:
            try:
                r = _decode(self.ws.recv(timeout=2.0))
            except Exception:
                break
            if not r:
                continue
            if r["code"]:
                raise RuntimeError("doubao error %s: %s" % (r["code"], r["text"][:200]))
            txt = _result_text(r.get("text") or "")
            if txt:
                self.last = txt
            if r["fl"] & 0x2:
                break
        return self.last

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


# ---------------------------------------------------------------- engines

def _ffmpeg(raw, extra, ext):
    """Decode arbitrary audio to `ext`. The output needs a real extension —
    ffmpeg picks the muxer from it."""
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "in")
        out = os.path.join(d, "out." + ext)
        with open(src, "wb") as f:
            f.write(raw)
        subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", src] + extra + [out],
                       check=True, timeout=30)
        return Path(out).read_bytes()


def to_wav(raw):
    return _ffmpeg(raw, ["-ar", "16000", "-ac", "1"], "wav")


def to_pcm(raw):
    return _ffmpeg(raw, ["-ar", "16000", "-ac", "1", "-f", "s16le"], "pcm")


def local_transcribe(wav):
    with LOCK:
        return MODEL.generate(wav, language="zh").text.strip()


def doubao_pcm(pcm):
    """Whole-buffer 豆包 transcription (non-streaming caller)."""
    dbg = os.environ.get("ASR_DEBUG") == "1"
    t0 = time.monotonic()
    s = DoubaoSession()
    t1 = time.monotonic()
    try:
        s.push(pcm, pace=DOUBAO_PACE)
        t2 = time.monotonic()
        text = s.finish()
        if dbg:
            print("doubao phases: feed %.2fs (sleep %.2f drain %.2f) tail %.2fs audio %.1fs"
                  % (t2 - t1, s.sleep_s, s.drain_s, time.monotonic() - t2,
                     len(pcm) / 32000.0), flush=True)
        return text
    finally:
        s.close()
        if dbg:
            print("doubao phases: handshake %.2fs total %.2fs"
                  % (t1 - t0, time.monotonic() - t0), flush=True)


def transcribe(raw):
    """-> (text, engine, asr_seconds, audio_seconds)"""
    wav = to_wav(raw)
    audio_s = (len(wav) - 44) / 32000.0
    t = time.monotonic()
    # 豆包 only pays off when the caller is already streaming (the /stream path).
    # Pushed whole-file it must be paced to stay clean, so a 14 s clip costs ~8.6 s
    # against local's 0.6 s. ASR_DOUBAO_WHOLEFILE=0 keeps the HTTP path pure-local.
    if DOUBAO_ENABLED and DOUBAO_WHOLEFILE and _key():
        try:
            text = doubao_pcm(to_pcm(raw)).strip()
            if text:
                return text, "doubao", time.monotonic() - t, audio_s
            print("doubao returned empty, falling back to local", flush=True)
        except Exception as exc:
            print("doubao failed (%s), falling back to local" % exc, flush=True)
    return local_transcribe(wav), "local", time.monotonic() - t, audio_s


# ---------------------------------------------------------------- HTTP

def _first_file_part(raw, content_type):
    boundary = None
    for piece in content_type.split(";"):
        piece = piece.strip()
        if piece.startswith("boundary="):
            boundary = piece[len("boundary="):].strip('"')
    if not boundary:
        return raw
    for part in raw.split(b"--" + boundary.encode()):
        head, sep, body = part.partition(b"\r\n\r\n")
        if sep and b"filename=" in head:
            return body.rstrip(b"\r\n")
    return raw


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/transcribe":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            self.send_error(400)
            return
        raw = _first_file_part(self.rfile.read(length), self.headers.get("Content-Type", ""))
        try:
            text, engine, asr_s, audio_s = transcribe(raw)
        except Exception as exc:
            print("asr error %s" % exc, flush=True)
            self._json({"error": str(exc)[:200]}, 500)
            return
        print("asr %.3fs audio=%.1fs engine=%s %r" % (asr_s, audio_s, engine, text[:60]), flush=True)
        self._json({"text": text, "engine": engine,
                    "asr_s": round(asr_s, 3), "audio_s": round(audio_s, 1)})

    def do_GET(self):
        if self.path == "/health":
            self._raw(b"ok", "text/plain")
        else:
            self.send_error(404)

    def _raw(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


# ---------------------------------------------------------------- WebSocket

def stream_handler(ws):
    """Binary PCM in, incremental transcripts out. Falls back to local at the end."""
    buf = bytearray()
    session = None
    sent = ""
    fallback = not (DOUBAO_ENABLED and _key())
    if not fallback:
        try:
            session = DoubaoSession()
        except Exception as exc:
            print("stream: doubao connect failed (%s), local fallback" % exc, flush=True)
            fallback = True
    try:
        for message in ws:
            if isinstance(message, (bytes, bytearray)):
                buf.extend(message)
                if session is not None:
                    try:
                        txt = session.push(bytes(message))
                    except Exception as exc:
                        print("stream: doubao feed failed (%s), local fallback" % exc, flush=True)
                        session = None
                        fallback = True
                        continue
                    if txt and txt != sent:
                        sent = txt
                        ws.send(json.dumps({"type": "partial", "text": txt, "definite": False},
                                           ensure_ascii=False))
                continue
            # text frame
            try:
                cmd = json.loads(message)
            except Exception:
                continue
            if cmd.get("type") == "end":
                break

        if session is not None:
            try:
                final = session.finish().strip()
            except Exception as exc:
                print("stream: doubao finish failed (%s)" % exc, flush=True)
                final = ""
            if final:
                ws.send(json.dumps({"type": "final", "text": final, "definite": True},
                                   ensure_ascii=False))
                return
            fallback = True

        if fallback:
            if len(buf) < 128:
                ws.send(json.dumps({"type": "error", "message": "录音太短"}, ensure_ascii=False))
                return
            wp = Path(tempfile.mkdtemp()) / "in.wav"
            wp.write_bytes(struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(buf), b"WAVE",
                                       b"fmt ", 16, 1, 1, 16000, 32000, 2, 16, b"data", len(buf))
                           + bytes(buf))
            text = local_transcribe(str(wp))
            ws.send(json.dumps({"type": "final", "text": text, "definite": True},
                               ensure_ascii=False))
    except Exception as exc:
        print("stream error %s" % exc, flush=True)
        try:
            ws.send(json.dumps({"type": "error", "message": str(exc)[:200]}, ensure_ascii=False))
        except Exception:
            pass
    finally:
        if session is not None:
            session.close()


def serve_ws():
    from websockets.sync.server import serve

    def handler(ws):
        if getattr(ws, "request", None) is not None:
            path = ws.request.path
            if path not in ("/stream", "/"):
                ws.close(code=1008, reason="unknown path")
                return
        stream_handler(ws)

    with serve(handler, "127.0.0.1", WS_PORT, max_size=MAX_BODY) as server:
        print("ws listening on 127.0.0.1:%d/stream" % WS_PORT, flush=True)
        server.serve_forever()


if __name__ == "__main__":
    sample = HERE / "samples" / "short.wav"
    if sample.exists():
        text, engine, asr_s, _ = transcribe(sample.read_bytes())
        print("warmup %.3fs engine=%s %r" % (asr_s, engine, text), flush=True)
    threading.Thread(target=serve_ws, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
