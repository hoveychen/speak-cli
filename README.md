# talk-cli

[![Release](https://img.shields.io/github/v/release/hoveychen/talk-cli)](https://github.com/hoveychen/talk-cli/releases/latest)
[![Go](https://img.shields.io/badge/go-1.22+-00ADD8?logo=go)](https://go.dev/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey)](https://github.com/hoveychen/talk-cli/releases/latest)

**talk-cli** is a fast, offline-capable multilingual text-to-speech CLI powered by [Kokoro](https://github.com/thewh1teagle/kokoro-onnx). It auto-detects language, supports 150+ voices, and uses the faster MLX backend automatically on Apple Silicon.

```bash
talk "Hello, world!"
talk "你好，欢迎使用 talk-cli"
talk -v af_sky -s 1.2 "Speed it up a bit"
talk --output hello.wav "Save to file"
```

---

## Features

- **Auto language detection** — switches between English and Chinese based on text content
- **150+ voices** — 54 English voices (American, British, Spanish, French, Hindi, Japanese, Portuguese, Italian) and 103 Chinese voices
- **Apple Silicon optimised** — uses MLX backend for English on M-series Macs, falls back to ONNX automatically
- **Offline after first use** — engine and models are cached in `~/.cache/talk-cli/`
- **Save to file** — export speech as WAV with `--output`
- **Tiny binary** — ~8 MB Go binary; engine and models are downloaded on demand

## Supported Platforms

| Platform | Architecture | Backend |
|----------|-------------|---------|
| macOS | Apple Silicon (arm64) | MLX (fast) + ONNX fallback |
| macOS | Intel (amd64) | ONNX |
| Windows | amd64 | ONNX |
| Linux | — | Export to file only (no audio playback) |

---

## Installation

### One-line install (recommended)

**macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/hoveychen/talk-cli/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
powershell -c "irm https://raw.githubusercontent.com/hoveychen/talk-cli/main/install.ps1 | iex"
```

Auto-detects your platform and architecture, installs to `~/.local/bin` (macOS) or `%LOCALAPPDATA%\talk-cli\bin` (Windows), and adds it to your PATH automatically.

To install a specific version or change the install directory:
```bash
# macOS
TALK_VERSION=v0.2.0 TALK_INSTALL_DIR=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/hoveychen/talk-cli/main/install.sh | bash

# Windows
$env:TALK_VERSION="v0.2.0"; $env:TALK_INSTALL_DIR="C:\Tools"; powershell -c "irm https://raw.githubusercontent.com/hoveychen/talk-cli/main/install.ps1 | iex"
```

### Build from source

Requires Go 1.22+.

```bash
git clone https://github.com/hoveychen/talk-cli.git
cd talk-cli
make build       # outputs to bin/
```

---

## Usage

### Speak text

```bash
talk "Hello, world!"                        # English (auto-detected)
talk "你好，欢迎使用 talk-cli"               # Chinese (auto-detected)
talk --lang zh "Kokoro is great"            # Force language
talk -v af_sky "Choose a specific voice"    # Choose voice
talk -s 1.5 "Speak 50% faster"             # Adjust speed (0.5–2.0)
talk -o out.wav "Save as WAV"              # Export to file
```

### List voices

```bash
talk voices              # All voices
talk voices --lang en    # English only
talk voices --lang zh    # Chinese only
```

### Pre-download assets (for offline use)

```bash
talk init                # Download both English and Chinese
talk init --lang en      # English only
talk init --lang zh      # Chinese only
```

### All flags

```
Flags:
      --lang string     Language: auto, en, zh (default "auto")
  -v, --voice string    Voice name (default depends on language)
  -s, --speed float     Speed multiplier 0.5–2.0 (default 1.0)
  -o, --output string   Save WAV to file instead of playing
      --no-progress     Suppress download progress bar
  -h, --help            Help
```

---

## How it works

On first use, `talk` downloads the appropriate engine bundle and model:

```
~/.cache/talk-cli/
├── en/
│   ├── engine/     # PyInstaller-packaged Kokoro ONNX or MLX engine
│   └── model/      # model.onnx + voices.bin (~88 MB INT8)
└── zh/
    ├── engine/     # PyInstaller-packaged Kokoro ONNX engine
    └── model/      # model.onnx + voices.bin + config.json (~82 MB INT8)
```

The Go binary manages downloads, invokes the engine subprocess with JSON arguments, and plays back the WAV output. Language auto-detection uses Unicode CJK block (U+4E00–U+9FFF).

---

## Models

| Language | Model | Size | Source |
|----------|-------|------|--------|
| English | Kokoro v1.0 (INT8 ONNX) | ~88 MB | [thewh1teagle/kokoro-onnx](https://huggingface.co/thewh1teagle/kokoro-onnx) |
| Chinese | Kokoro v1.1-zh (INT8 ONNX) | ~82 MB | [hoveyc/talk-cli-models](https://huggingface.co/hoveyc/talk-cli-models) |
| English (MLX) | Kokoro-82M-bf16 | streamed | [mlx-community/Kokoro-82M-bf16](https://huggingface.co/mlx-community/Kokoro-82M-bf16) |

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## License

[MIT](LICENSE)
