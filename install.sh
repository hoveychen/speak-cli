#!/usr/bin/env bash
# Works on macOS and Linux. Downloads the right binary. You're welcome.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hoveychen/speak-cli/main/install.sh | bash
#
# Options (env vars):
#   SPEAK_VERSION=v0.2.0   install a specific version (default: latest)
#   SPEAK_INSTALL_DIR=/usr/local/bin  install location (default: ~/.local/bin)

set -euo pipefail

REPO="hoveychen/speak-cli"
BINARY_NAME="speak"
INSTALL_DIR="${SPEAK_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${SPEAK_VERSION:-}"

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
      arm64)  ASSET="speak-darwin-arm64" ;;
      x86_64) ASSET="speak-darwin-amd64" ;;
      *)      die "Unsupported macOS architecture: $ARCH" ;;
    esac
    ;;
  Linux)
    die "Linux binaries are not yet published. Build from source: https://github.com/$REPO"
    ;;
  *)
    die "Unsupported OS: $OS. On Windows, download speak-windows-amd64.exe from https://github.com/$REPO/releases"
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
printf "\n${BOLD}Installing speak ${VERSION}${RESET} (${OS}/${ARCH})\n\n"

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

# ── listener daemon (macOS only) ─────────────────────────────────────────────
# The listener binary is embedded in speak. We set up a LaunchAgent so the
# daemon starts automatically at login and any caller (VS Code, AI tools, etc.)
# can use speech recognition without needing microphone permission themselves.
if [ "$OS" = "Darwin" ]; then
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST_LABEL="com.speak-cli.listener"
  PLIST_FILE="$PLIST_DIR/$PLIST_LABEL.plist"
  LOG_DIR="$HOME/Library/Logs/speak-cli"
  mkdir -p "$PLIST_DIR" "$LOG_DIR"

  cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${DEST}</string>
    <string>listen</string>
    <string>--daemon</string>
    <string>--lang</string>
    <string>auto</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/listener.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/listener.log</string>
</dict>
</plist>
PLIST

  # Stop existing daemon if running, then start the new one.
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE"
  ok "Listener daemon installed and started"
  info "Logs: $LOG_DIR/listener.log"
  info "Stop:  launchctl bootout gui/\$(id -u)/$PLIST_LABEL"
fi

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
printf "\n${GREEN}${BOLD}All done!${RESET} Run: ${BOLD}speak \"Hello, world!\"${RESET}\n\n"
