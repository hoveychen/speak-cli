#!/usr/bin/env python3
"""
Kokoro TTS engine wrapper.

Called by the Go CLI as a subprocess. Speaks text or lists voices.

Usage:
  kokoro_engine speak  --model <path> --voices <path> --text <text>
                       --voice <voice> --speed <float> --lang <code>
                       --output <wav_path>
  kokoro_engine voices --model <path> --voices <path>
"""

import sys
import json
import argparse
import os


def load_kokoro(model_path: str, voices_path: str, config_path: str = None):
    from kokoro_onnx import Kokoro
    if config_path:
        return Kokoro(model_path, voices_path, vocab_config=config_path)
    return Kokoro(model_path, voices_path)


def do_speak(kokoro, text, voice, speed, lang, output):
    """Core synthesis: phonemize + generate + write WAV."""
    import soundfile as sf
    if lang == "z":
        phonemes = phonemize_zh(text)
        samples, sample_rate = kokoro.create(
            phonemes, voice=voice, speed=speed, is_phonemes=True,
        )
    else:
        _LANG_MAP = {
            "a": "en-us", "b": "en-gb", "j": "ja", "z": "zh",
            "e": "es", "f": "fr-fr", "h": "hi", "i": "it", "p": "pt-br",
        }
        bcp47 = _LANG_MAP.get(lang, lang)
        samples, sample_rate = kokoro.create(
            text, voice=voice, speed=speed, lang=bcp47, is_phonemes=False,
        )
    sf.write(output, samples, sample_rate)


def phonemize_zh(text: str) -> str:
    """Convert Chinese text to phonemes using misaki ZHG2P(version='1.1').

    version='1.1' uses ZHFrontend (Zhuyin-based) which matches the training
    phoneme format of the kokoro-v1.1-zh model and produces correct quality.
    Compatible with both misaki 0.7.x (returns str) and 0.9.x+ (returns (str, None)).
    """
    from misaki import zh as mzh
    g2p = mzh.ZHG2P(version='1.1')
    result = g2p(text)
    # misaki >=0.9: returns (phonemes, extra); misaki 0.7: returns plain str
    if isinstance(result, tuple):
        return result[0]
    return result


def cmd_speak(args):
    config = getattr(args, 'config', None) or None
    kokoro = load_kokoro(args.model, args.voices, config)
    do_speak(kokoro, args.text, args.voice, args.speed, args.lang, args.output)


def cmd_serve(args):
    """Long-running daemon: load model once, accept requests via Unix socket."""
    import socket
    import threading
    import time

    config = getattr(args, 'config', None) or None
    kokoro = load_kokoro(args.model, args.voices, config)

    sock_path = args.sock
    idle_timeout = args.idle_timeout

    # Clean up stale socket file.
    if os.path.exists(sock_path):
        os.remove(sock_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(4)
    server.settimeout(1.0)  # poll interval for idle check

    last_active = [time.time()]
    lock = threading.Lock()
    running = [True]

    # Signal readiness to the launcher (Go caller reads this line from stdout).
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    while running[0]:
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
                    do_speak(
                        kokoro,
                        req["text"], req["voice"], req.get("speed", 1.0),
                        req.get("lang", "a"), req["output"],
                    )
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
    # voices.bin is a numpy archive: keys are voice names, values are embeddings.
    import numpy as np
    try:
        data = np.load(args.voices, allow_pickle=True).item()
        names = sorted(data.keys())
    except Exception:
        # Fallback: instantiate Kokoro and call get_voices() if available.
        config = getattr(args, 'config', None) or None
        kokoro = load_kokoro(args.model, args.voices, config)
        if hasattr(kokoro, "get_voices"):
            names = sorted(kokoro.get_voices())
        else:
            print("[]")
            return
    print(json.dumps(names))


def main():
    parser = argparse.ArgumentParser(prog="kokoro_engine")
    sub = parser.add_subparsers(dest="command", required=True)

    # ── speak ─────────────────────────────────────────────────────────────────
    sp = sub.add_parser("speak")
    sp.add_argument("--model",  required=True, help="Path to model.onnx")
    sp.add_argument("--voices", required=True, help="Path to voices.bin")
    sp.add_argument("--text",   required=True, help="Text to synthesise")
    sp.add_argument("--voice",  default="af_sky", help="Voice name")
    sp.add_argument("--speed",  type=float, default=1.0, help="Speed multiplier")
    sp.add_argument("--lang",   default="a",
                    help="Language code: a=en-US, b=en-GB, j=ja, z=zh, "
                         "e=es, f=fr, h=hi, i=it, p=pt-BR")
    sp.add_argument("--config", default="", help="Path to model config.json for custom vocab (zh)")
    sp.add_argument("--output", required=True, help="Output WAV file path")

    # ── voices ────────────────────────────────────────────────────────────────
    vp = sub.add_parser("voices")
    vp.add_argument("--model",  required=True, help="Path to model.onnx")
    vp.add_argument("--voices", required=True, help="Path to voices.bin")
    vp.add_argument("--config", default="", help="Path to model config.json for custom vocab (zh)")

    # ── serve (daemon mode) ──────────────────────────────────────────────────
    sv = sub.add_parser("serve")
    sv.add_argument("--model",  required=True, help="Path to model.onnx")
    sv.add_argument("--voices", required=True, help="Path to voices.bin")
    sv.add_argument("--config", default="", help="Path to model config.json for custom vocab (zh)")
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
    main()
