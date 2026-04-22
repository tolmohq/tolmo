#!/bin/sh
# Tolmo CLI installer
# Usage:
#   curl -fsSL https://tolmo.com/install.sh | sh
#   curl -fsSL https://tolmo.com/install.sh | sh -s -- --nightly
set -eu

REPO="tolmohq/tolmo"
INSTALL_DIR="/usr/local/bin"
NIGHTLY=false

for arg in "$@"; do
  case "$arg" in
    --nightly) NIGHTLY=true ;;
    --help|-h)
      echo "Usage: install.sh [--nightly]"
      echo "  --nightly  Install the latest nightly pre-release"
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

is_debian_based() {
  has_cmd dpkg && has_cmd apt-get
}

verify_checksum() {
  local file="$1"
  local expected="$2"

  if [ -z "$expected" ]; then
    echo "Warning: checksum not found, skipping verification" >&2
    return 0
  fi

  local actual
  if has_cmd sha256sum; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  elif has_cmd shasum; then
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  else
    echo "Warning: no sha256sum or shasum available, skipping verification" >&2
    return 0
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
    echo "  brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo && brew install tolmo@nightly"
    echo ""
  else
    echo "Homebrew detected. You can also install via:"
    echo "  brew tap tolmohq/tolmo https://github.com/tolmohq/tolmo && brew install tolmo"
    echo ""
  fi
fi

echo "Detecting platform: ${OS}/${ARCH}"

# Fetch the right release
if [ "$NIGHTLY" = true ]; then
  echo "Fetching latest nightly pre-release..."
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases" \
    | grep -o '"tag_name":[[:space:]]*"[^"]*-nightly\.[^"]*"' \
    | head -1 \
    | cut -d'"' -f4)"
  if [ -z "$TAG" ]; then
    echo "Error: no nightly release found" >&2
    exit 1
  fi
  VERSION="${TAG#v}"
  ARCHIVE_PREFIX="tolmo-nightly"
else
  echo "Fetching latest stable release..."
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"tag_name":[[:space:]]*"[^"]*"' \
    | head -1 \
    | cut -d'"' -f4)"
  if [ -z "$TAG" ]; then
    echo "Error: no stable release found" >&2
    exit 1
  fi
  VERSION="${TAG#v}"
  ARCHIVE_PREFIX="tolmo"
fi

echo "Installing tolmo ${TAG}..."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Download checksums
CHECKSUMS_URL="https://github.com/${REPO}/releases/download/${TAG}/checksums.txt"
curl -fsSL -o "${TMPDIR}/checksums.txt" "$CHECKSUMS_URL" 2>/dev/null || true

# On Debian/Ubuntu with .deb available, use dpkg
if [ "$OS" = "linux" ] && is_debian_based; then
  if [ "$NIGHTLY" = true ]; then
    DEB_NAME="tolmo-nightly_${VERSION}_${OS}_${ARCH}.deb"
  else
    DEB_NAME="tolmo_${VERSION}_${OS}_${ARCH}.deb"
  fi
  DEB_URL="https://github.com/${REPO}/releases/download/${TAG}/${DEB_NAME}"

  echo "Downloading ${DEB_NAME}..."
  curl -fsSL -o "${TMPDIR}/${DEB_NAME}" "$DEB_URL"

  EXPECTED="$(grep "${DEB_NAME}$" "${TMPDIR}/checksums.txt" 2>/dev/null | cut -d' ' -f1 || true)"
  verify_checksum "${TMPDIR}/${DEB_NAME}" "$EXPECTED"

  echo "Installing .deb package (requires sudo)..."
  sudo dpkg -i "${TMPDIR}/${DEB_NAME}"

  echo "Installed successfully!"
  tolmo --version
  exit 0
fi

# Otherwise, use tarball
ARCHIVE_NAME="${ARCHIVE_PREFIX}_${VERSION}_${OS}_${ARCH}.tar.gz"
ARCHIVE_URL="https://github.com/${REPO}/releases/download/${TAG}/${ARCHIVE_NAME}"

echo "Downloading ${ARCHIVE_NAME}..."
curl -fsSL -o "${TMPDIR}/${ARCHIVE_NAME}" "$ARCHIVE_URL"

EXPECTED="$(grep "${ARCHIVE_NAME}$" "${TMPDIR}/checksums.txt" 2>/dev/null | cut -d' ' -f1 || true)"
verify_checksum "${TMPDIR}/${ARCHIVE_NAME}" "$EXPECTED"

echo "Extracting..."
tar -xzf "${TMPDIR}/${ARCHIVE_NAME}" -C "$TMPDIR"

# Install binary
if [ -w "$INSTALL_DIR" ]; then
  cp "${TMPDIR}/tolmo" "${INSTALL_DIR}/tolmo"
  chmod +x "${INSTALL_DIR}/tolmo"
else
  echo "Installing to ${INSTALL_DIR} (requires sudo)..."
  sudo cp "${TMPDIR}/tolmo" "${INSTALL_DIR}/tolmo"
  sudo chmod +x "${INSTALL_DIR}/tolmo"
fi

echo "Installed successfully!"
"${INSTALL_DIR}/tolmo" --version
