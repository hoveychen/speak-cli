SHELL := /bin/bash
MODULE := github.com/hoveychen/talk-cli

HOST_OS   := $(shell go env GOOS)
HOST_ARCH := $(shell go env GOARCH)

.PHONY: all build build-engine-darwin build-engine-darwin-mlx build-engine-windows \
        release-engines upload-models clean

# ─── Default ─────────────────────────────────────────────────────────────────

all: build

# ─── Go build ────────────────────────────────────────────────────────────────

# Build the talk CLI for all supported platforms.
build:
	@echo "→ Building talk..."
	@mkdir -p bin
	@GOOS=darwin  GOARCH=arm64 go build -ldflags="-s -w" \
	    -o bin/talk-darwin-arm64      ./cmd/talk
	@GOOS=darwin  GOARCH=amd64 go build -ldflags="-s -w" \
	    -o bin/talk-darwin-amd64      ./cmd/talk
	@GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" \
	    -o bin/talk-windows-amd64.exe ./cmd/talk
	@echo "✓ talk binaries in bin/"

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
# Default repo: hoveyc/talk-cli-models  (override with REPO=<owner/name>)
upload-models:
	@bash scripts/upload-models-hf.sh --repo "${REPO:-hoveyc/talk-cli-models}"

# ─── Housekeeping ────────────────────────────────────────────────────────────

clean:
	rm -rf bin/ release/ engine/build-*/ engine/dist-*/ engine/__pycache__/ engine/*.spec
