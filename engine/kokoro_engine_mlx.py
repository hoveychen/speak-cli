#!/usr/bin/env python3
"""
Kokoro TTS engine wrapper for Apple Silicon (MLX backend).

Called by the Go CLI as a subprocess. Speaks text or lists voices.
Requires Apple Silicon (M-series) Mac — MLX does not run on Intel or Windows.

Usage:
  kokoro_engine_mlx speak  --model <hf_id_or_path> --voices <ignored>
                            --text <text> --voice <voice> --speed <float>
                            --lang <ignored> --output <wav_path>
  kokoro_engine_mlx voices --model <hf_id_or_path> --voices <ignored>

Notes:
  --model   HuggingFace model ID or local directory.
            Defaults to "mlx-community/Kokoro-82M-bf16".
            On first use the model is downloaded to the HF hub cache
            (~/.cache/huggingface/hub/). Subsequent runs use the cache.
  --voices  Accepted for interface compatibility but ignored; voice
            embeddings are part of the downloaded model.
  --lang    Accepted for interface compatibility but ignored; the voice
            name encodes the language (af_ = American-English, zf_ = zh, …).
"""

import multiprocessing
import sys
import json
import argparse

DEFAULT_MODEL = "mlx-community/Kokoro-82M-bf16"


def load_tts(model_id_or_path: str):
    from kokoro_mlx import KokoroTTS
    return KokoroTTS.from_pretrained(model_id_or_path)


def do_speak(tts, text, voice, speed, output):
    """Core synthesis: generate + write WAV."""
    import soundfile as sf
    result = tts.generate(text, voice=voice, speed=speed)
    sf.write(output, result.audio, result.sample_rate)


def cmd_speak(args):
    tts = load_tts(args.model)
    do_speak(tts, args.text, args.voice, args.speed, args.output)


def cmd_serve(args):
    """Long-running daemon: load model once, accept requests via Unix socket."""
    import socket
    import threading
    import time
    import os

    tts = load_tts(args.model)

    sock_path = args.sock
    idle_timeout = args.idle_timeout

    if os.path.exists(sock_path):
        os.remove(sock_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(4)
    server.settimeout(1.0)

    last_active = [time.time()]
    lock = threading.Lock()

    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    while True:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            if idle_timeout > 0 and time.time() - last_active[0] > idle_timeout:
                print("Idle timeout reached, shutting down.", file=sys.stderr)
                break
            continue

        try:
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            line = data.decode("utf-8").strip()
            if not line:
                conn.close()
                continue

            req = json.loads(line)
            req_id = req.get("id", "")
            method = req.get("method", "")

            with lock:
                last_active[0] = time.time()

            if method == "speak":
                try:
                    do_speak(tts, req["text"], req["voice"], req.get("speed", 1.0), req["output"])
                    resp = json.dumps({"id": req_id, "ok": True})
                except Exception as exc:
                    resp = json.dumps({"id": req_id, "ok": False, "error": str(exc)})
            elif method == "shutdown":
                resp = json.dumps({"id": req_id, "ok": True})
                conn.sendall((resp + "\n").encode("utf-8"))
                conn.close()
                break
            else:
                resp = json.dumps({"id": req_id, "ok": False, "error": f"unknown method: {method}"})

            conn.sendall((resp + "\n").encode("utf-8"))
        except Exception as exc:
            try:
                resp = json.dumps({"ok": False, "error": str(exc)})
                conn.sendall((resp + "\n").encode("utf-8"))
            except Exception:
                pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    server.close()
    try:
        os.remove(sock_path)
    except OSError:
        pass


def cmd_voices(args):
    tts = load_tts(args.model)
    names = tts.list_voices()
    print(json.dumps(names))


def main():
    parser = argparse.ArgumentParser(prog="kokoro_engine_mlx")
    sub = parser.add_subparsers(dest="command", required=True)

    # ── speak ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser("speak")
    sp.add_argument("--model",  default=DEFAULT_MODEL,
                    help="HuggingFace model ID or local path (default: mlx-community/Kokoro-82M-bf16)")
    sp.add_argument("--voices", default="", help="Ignored — voices are embedded in the model")
    sp.add_argument("--text",   required=True, help="Text to synthesise")
    sp.add_argument("--voice",  default="af_heart", help="Voice name")
    sp.add_argument("--speed",  type=float, default=1.0, help="Speed multiplier")
    sp.add_argument("--lang",   default="",
                    help="Ignored — language is encoded in the voice name")
    sp.add_argument("--output", required=True, help="Output WAV file path")

    # ── voices ────────────────────────────────────────────────────────────────
    vp = sub.add_parser("voices")
    vp.add_argument("--model",  default=DEFAULT_MODEL,
                    help="HuggingFace model ID or local path")
    vp.add_argument("--voices", default="", help="Ignored")

    # ── serve (daemon mode) ──────────────────────────────────────────────────
    sv = sub.add_parser("serve")
    sv.add_argument("--model",  default=DEFAULT_MODEL,
                    help="HuggingFace model ID or local path")
    sv.add_argument("--sock",   required=True, help="Unix socket path to listen on")
    sv.add_argument("--idle-timeout", type=int, default=300, dest="idle_timeout",
                    help="Shut down after N seconds of inactivity (0=never, default=300)")

    args = parser.parse_args()

    try:
        if args.command == "speak":
            cmd_speak(args)
        elif args.command == "voices":
            cmd_voices(args)
        elif args.command == "serve":
            cmd_serve(args)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    # Required for PyInstaller frozen executables that use multiprocessing.
    multiprocessing.freeze_support()
    main()
