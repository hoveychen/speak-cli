SHELL := /bin/bash
MODULE := github.com/hoveychen/speak-cli

HOST_OS   := $(shell go env GOOS)
HOST_ARCH := $(shell go env GOARCH)

.PHONY: all build build-listener build-engine-darwin build-engine-darwin-mlx build-engine-windows \
        release-engines upload-models clean

# ─── Default ─────────────────────────────────────────────────────────────────

all: build

# ─── Go build ────────────────────────────────────────────────────────────────

# Build the speak CLI for all supported platforms.
# Listener binaries must be pre-built in internal/listener/ for embedding.
build:
	@echo "→ Building speak..."
	@mkdir -p bin
	@GOOS=darwin  GOARCH=arm64 go build -ldflags="-s -w" \
	    -o bin/speak-darwin-arm64      ./cmd/speak
	@GOOS=darwin  GOARCH=amd64 go build -ldflags="-s -w" \
	    -o bin/speak-darwin-amd64      ./cmd/speak
	@GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" \
	    -o bin/speak-windows-amd64.exe ./cmd/speak
	@echo "✓ speak binaries in bin/"

# Build everything for the current platform (listener + Go CLI with embed).
build-all: build-listener embed-listener build

# Copy listener binary into internal/listener/ for Go embed.
embed-listener:
ifeq ($(HOST_OS),darwin)
	@cp bin/speak-listen internal/listener/speak-listen
	@echo "✓ speak-listen embedded for darwin"
else ifeq ($(HOST_OS),windows)
	@cp bin/speak-listen.exe internal/listener/speak-listen.exe
	@echo "✓ speak-listen.exe embedded for windows"
endif

# ─── Listener (native ASR) ───────────────────────────────────────────────

# Build the native speech-recognition binary for the current platform.
build-listener:
ifeq ($(HOST_OS),darwin)
	@echo "→ Building macOS listener ($(HOST_ARCH))..."
	@mkdir -p bin
	@swiftc listen/listen_darwin.swift \
	    -o bin/speak-listen \
	    -framework Cocoa -framework Speech -framework AVFoundation \
	    -O -target $(HOST_ARCH)-apple-macos13
	@echo "✓ bin/speak-listen"
else
	@echo "⚠ Use scripts\\build-listener-windows.bat on Windows"
endif

# ─── Engine builds ───────────────────────────────────────────────────────────

# Build the universal ONNX engine bundles for macOS (arm64 + amd64).
# Output: assets/engine-darwin-{arm64,amd64}-onnx.tar.gz
build-engine-darwin:
	@echo "→ Building macOS ONNX engines..."
	@bash scripts/build-engine-macos.sh

# Build the MLX engine bundle for Apple Silicon.
# Output: assets/engine-darwin-arm64-mlx.tar.gz
build-engine-darwin-mlx:
	@echo "→ Building macOS MLX engine..."
	@bash scripts/build-engine-macos-mlx.sh

# Build the ONNX engine bundle for Windows amd64 (run on Windows or via CI).
# Output: assets/engine-windows-amd64-onnx.zip
build-engine-windows:
	@echo "→ Building Windows ONNX engine..."
	@powershell -ExecutionPolicy Bypass -File scripts/build-engine-windows.ps1

# ─── Release: package engine bundles for GitHub Releases ─────────────────────

# Collect built engine archives into release/ for uploading as GitHub Release
# assets under the tag defined in internal/assets/versions.go (EngineTag).
#
# After building engines on each platform, run:
#   gh release create engine-v0.1.0 release/engine-*.tar.gz release/engine-*.zip
release-engines:
	@echo "→ Packaging engine bundles..."
	@mkdir -p release
	@for f in \
	    assets/engine-darwin-arm64-onnx.tar.gz \
	    assets/engine-darwin-amd64-onnx.tar.gz \
	    assets/engine-darwin-arm64-mlx.tar.gz  \
	    assets/engine-windows-amd64-onnx.zip;  \
	  do [ -f "$$f" ] && cp "$$f" release/ && echo "  $$f" || true; done
	@echo "✓ Engine bundles ready in release/"

# ─── HuggingFace model upload ─────────────────────────────────────────────────

# Upload ONNX models, voices, and config to HuggingFace.
# Requires: huggingface-cli and assets/{en,zh}/model.onnx + voices.bin.
# Default repo: hoveyc/speak-cli-models  (override with REPO=<owner/name>)
upload-models:
	@bash scripts/upload-models-hf.sh --repo "${REPO:-hoveyc/speak-cli-models}"

# ─── Housekeeping ────────────────────────────────────────────────────────────

clean:
	rm -rf bin/ release/ engine/build-*/ engine/dist-*/ engine/__pycache__/ engine/*.spec
