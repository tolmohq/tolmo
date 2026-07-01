#!/bin/sh
# Tolmo CLI installer
# Usage:
#   curl -fsSL https://tolmo.com/install.sh | sh
#   curl -fsSL https://tolmo.com/install.sh | sh -s -- --nightly
set -eu

REPO="tolmohq/tolmo"
INSTALL_DIR="${TOLMO_INSTALL_DIR:-}"
SYSTEM_BIN_DIR="${TOLMO_SYSTEM_BIN_DIR:-/usr/local/bin}"
NIGHTLY=false

for arg in "$@"; do
  case "$arg" in
    --nightly) NIGHTLY=true ;;
    --help|-h)
      echo "Usage: install.sh [--nightly]"
      echo "  --nightly  Install the latest nightly pre-release"
      echo ""
      echo "Environment:"
      echo "  TOLMO_INSTALL_DIR  Install directory override"
      exit 0
      ;;
  esac
done

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)
      echo "Error: unsupported OS: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    *)
      echo "Error: unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

default_install_dir() {
  if [ -d "$SYSTEM_BIN_DIR" ] && [ -w "$SYSTEM_BIN_DIR" ]; then
    echo "$SYSTEM_BIN_DIR"
    return 0
  fi

  if [ -z "${HOME:-}" ]; then
    echo "Error: HOME is unset; set TOLMO_INSTALL_DIR to a writable directory" \
      >&2
    return 1
  fi

  echo "${HOME}/.local/bin"
  return 0
}

path_contains() {
  case ":${PATH:-}:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

INSTALL_TMP=""

install_binary() {
  local source="$1"
  local target="$2"
  local target_tmp="${target}.tmp.$$"

  if [ -d "$target" ]; then
    echo "Error: ${target} is a directory" >&2
    return 1
  fi

  # Sweep stale temp files from prior SIGKILL/OOM-killed runs.
  rm -f "${target}.tmp."* 2>/dev/null || true

  INSTALL_TMP="$target_tmp"
  cp "$source" "$target_tmp"
  chmod +x "$target_tmp"
  mv -f "$target_tmp" "$target" 2>/dev/null || {
    rm -f "$target_tmp" 2>/dev/null || true
    INSTALL_TMP=""
    echo "Error: ${target} could not be replaced" >&2
    return 1
  }
  INSTALL_TMP=""
}

verify_checksum() {
  local file="$1"
  local expected="$2"

  if [ -z "$expected" ]; then
    echo "Error: expected checksum is empty — checksums.txt is missing or does not list this archive" >&2
    return 1
  fi

  local actual
  if has_cmd sha256sum; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  elif has_cmd shasum; then
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  else
    echo "Error: no sha256sum or shasum found — cannot verify binary integrity" >&2
    echo "Install coreutils (Linux) or the Xcode Command Line Tools (macOS) and retry." >&2
    return 1
  fi

  if [ "$actual" != "$expected" ]; then
    echo "Error: checksum verification failed" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    return 1
  fi

  echo "Checksum verified."
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

if [ -z "$INSTALL_DIR" ]; then
  INSTALL_DIR="$(default_install_dir)" || exit 1
fi

# Detect Rosetta 2: if running as x86_64 under translation on ARM Mac,
# download the native arm64 binary instead
if [ "$OS" = "darwin" ] && [ "$ARCH" = "amd64" ]; then
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
    ARCH="arm64"
    echo "Rosetta 2 detected, using native arm64 binary"
  fi
fi

# Recommend Homebrew on macOS if available
if [ "$OS" = "darwin" ] && has_cmd brew; then
  if [ "$NIGHTLY" = true ]; then
    echo "Homebrew detected. You can also install nightly via:"
    echo "  brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo && brew install tolmohq/tolmo/tolmo-nightly"
    echo ""
  else
    echo "Homebrew detected. You can also install via:"
    echo "  brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo && brew install tolmohq/tolmo/tolmo"
    echo ""
  fi
fi

echo "Detecting platform: ${OS}/${ARCH}"

# Resolve the release tag WITHOUT calling api.github.com. Its unauthenticated
# REST API is capped at 60 requests/hour/IP — easily exhausted behind NAT/VPN,
# and by Nix itself (it hits the same API to resolve nixpkgs), so the call would
# 403 and the old code mistranslated that into "no release found" (TOL-1412).
# github.com's web endpoints below carry no such limit.
if [ "$NIGHTLY" = true ]; then
  echo "Fetching latest nightly pre-release..."
  # releases.atom lists every release newest-first, prereleases included.
  TAG="$(curl -fsSL "https://github.com/${REPO}/releases.atom" \
    | grep -o 'releases/tag/[^"]*-nightly\.[^"]*' \
    | sed 's#releases/tag/##' \
    | head -1)"
  ARCHIVE_PREFIX="tolmo-nightly"
  RELEASE_KIND="nightly pre-release"
else
  echo "Fetching latest stable release..."
  # /releases/latest 302-redirects to /releases/tag/<TAG>; read the tag from the
  # resolved URL (HEAD only, no body download).
  TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}\n' \
    "https://github.com/${REPO}/releases/latest" \
    | sed -n 's#.*/releases/tag/##p')"
  ARCHIVE_PREFIX="tolmo"
  RELEASE_KIND="stable release"
fi

if [ -z "$TAG" ]; then
  echo "Error: could not determine the latest ${RELEASE_KIND} from GitHub." >&2
  echo "Check your network connection and retry. To install manually, download" >&2
  echo "a release from:" >&2
  echo "  https://github.com/${REPO}/releases" >&2
  exit 1
fi
VERSION="${TAG#v}"

echo "Installing tolmo ${TAG}..."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; if [ -n "$INSTALL_TMP" ]; then rm -f "$INSTALL_TMP"; fi' EXIT

# Download checksums — fail hard if unavailable; an absent file must not be
# silently treated as "no verification needed" (that is the attack surface).
CHECKSUMS_URL="https://github.com/${REPO}/releases/download/${TAG}/checksums.txt"
if ! curl -fsSL -o "${TMPDIR}/checksums.txt" "$CHECKSUMS_URL"; then
  echo "Error: failed to download checksums.txt from ${CHECKSUMS_URL}" >&2
  exit 1
fi
if [ ! -s "${TMPDIR}/checksums.txt" ]; then
  echo "Error: checksums.txt is empty" >&2
  exit 1
fi

ARCHIVE_NAME="${ARCHIVE_PREFIX}_${VERSION}_${OS}_${ARCH}.tar.gz"
ARCHIVE_URL="https://github.com/${REPO}/releases/download/${TAG}/${ARCHIVE_NAME}"

echo "Downloading ${ARCHIVE_NAME}..."
curl -fsSL -o "${TMPDIR}/${ARCHIVE_NAME}" "$ARCHIVE_URL"

EXPECTED="$(grep "${ARCHIVE_NAME}$" "${TMPDIR}/checksums.txt" | cut -d' ' -f1)"
verify_checksum "${TMPDIR}/${ARCHIVE_NAME}" "$EXPECTED"

echo "Extracting..."
tar -xzf "${TMPDIR}/${ARCHIVE_NAME}" -C "$TMPDIR"

# Install binary
if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
  echo "Error: could not create ${INSTALL_DIR}." >&2
  echo "Set TOLMO_INSTALL_DIR to a writable directory and rerun install.sh." \
    >&2
  exit 1
fi
if [ -w "$INSTALL_DIR" ]; then
  echo "Installing to ${INSTALL_DIR}..."
  install_binary "${TMPDIR}/tolmo" "${INSTALL_DIR}/tolmo"
else
  echo "Error: ${INSTALL_DIR} is not writable." >&2
  echo "Set TOLMO_INSTALL_DIR to a writable directory and rerun install.sh." \
    >&2
  exit 1
fi

echo "Installed successfully!"
"${INSTALL_DIR}/tolmo" --version

if ! path_contains "$INSTALL_DIR"; then
  echo ""
  echo "Add tolmo to your PATH:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi
