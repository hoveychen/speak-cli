#!/usr/bin/env bash
# Works on macOS and Linux. Downloads the right binary. You're welcome.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hoveychen/talk-cli/main/install.sh | bash
#
# Options (env vars):
#   TALK_VERSION=v0.2.0   install a specific version (default: latest)
#   TALK_INSTALL_DIR=/usr/local/bin  install location (default: ~/.local/bin)

set -euo pipefail

REPO="hoveychen/talk-cli"
BINARY_NAME="talk"
INSTALL_DIR="${TALK_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${TALK_VERSION:-}"

# ── colours ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info()  { printf "${CYAN}  →${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}  ✓${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}  !${RESET} %s\n" "$*"; }
die()   { printf "${RED}  ✗${RESET} %s\n" "$*" >&2; exit 1; }

# ── detect platform ───────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    case "$ARCH" in
      arm64)  ASSET="talk-darwin-arm64" ;;
      x86_64) ASSET="talk-darwin-amd64" ;;
      *)      die "Unsupported macOS architecture: $ARCH" ;;
    esac
    ;;
  Linux)
    die "Linux binaries are not yet published. Build from source: https://github.com/$REPO"
    ;;
  *)
    die "Unsupported OS: $OS. On Windows, download talk-windows-amd64.exe from https://github.com/$REPO/releases"
    ;;
esac

# ── resolve version ───────────────────────────────────────────────────────────
if [ -z "$VERSION" ]; then
  info "Fetching latest release..."
  if command -v curl &>/dev/null; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  elif command -v wget &>/dev/null; then
    VERSION="$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  else
    die "curl or wget is required"
  fi
  [ -n "$VERSION" ] || die "Could not determine latest version"
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"

# ── download ──────────────────────────────────────────────────────────────────
printf "\n${BOLD}Installing talk ${VERSION}${RESET} (${OS}/${ARCH})\n\n"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

info "Downloading $ASSET..."
if command -v curl &>/dev/null; then
  curl -fsSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_FILE"
else
  wget -q --show-progress "$DOWNLOAD_URL" -O "$TMP_FILE"
fi

# ── install ───────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$BINARY_NAME"
mv "$TMP_FILE" "$DEST"
chmod +x "$DEST"
ok "Installed to $DEST"

# ── PATH check ────────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    warn "$INSTALL_DIR is not in your PATH."
    printf "\n  Add this to your shell profile (~/.zshrc or ~/.bashrc):\n"
    printf "\n    ${CYAN}export PATH=\"\$PATH:$INSTALL_DIR\"${RESET}\n\n"
    ;;
esac

# ── done ──────────────────────────────────────────────────────────────────────
printf "\n${GREEN}${BOLD}All done!${RESET} Run: ${BOLD}talk \"Hello, world!\"${RESET}\n\n"
