#!/bin/sh
# Tolmo CLI installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tolmohq/tolmo/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/tolmohq/tolmo/main/install.sh | sh -s -- --nightly
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

install_wrapper() {
  target_dir="$1"
  real_bin_name="$2"
  wrapper_path="${target_dir}/tolmo"
  real_bin_path="${target_dir}/${real_bin_name}"

  cat > "${wrapper_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REAL_BIN="__REAL_BIN__"

is_short_finding_id() {
  local candidate="${1:-}"
  [[ -n "$candidate" && ${#candidate} -lt 36 && "$candidate" =~ ^[0-9A-Fa-f-]+$ ]]
}

resolve_finding_id() {
  local prefix="$1"
  shift

  local findings_json=""
  if ! findings_json="$("$REAL_BIN" "$@" findings list --json)"; then
    echo "Error: failed to list findings while resolving short id '$prefix'" >&2
    return 1
  fi

  local matches=""
  local status=0
  set +e
  matches="$(printf '%s' "$findings_json" | perl -MJSON::PP -e '
use strict;
use warnings;

my $prefix = lc(shift @ARGV // q{});
local $/;
my $raw = <STDIN>;
my $data = eval { JSON::PP::decode_json($raw) };
if (!$data || ref($data) ne "ARRAY") {
  exit 2;
}

my @matches = grep { index(lc($_), $prefix) == 0 }
              map { ref($_) eq "HASH" && defined $_->{id} ? $_->{id} : () } @$data;

if (@matches == 1) {
  print $matches[0];
  exit 0;
}

if (@matches == 0) {
  exit 3;
}

print join("\n", @matches);
exit 4;
' "$prefix")"
  status=$?
  set -e

  case "$status" in
    0)
      printf '%s' "$matches"
      ;;
    3)
      echo "Error: no finding matches short id '$prefix'" >&2
      return 1
      ;;
    4)
      echo "Error: short id '$prefix' is ambiguous. Matching IDs:" >&2
      printf '%s\n' "$matches" >&2
      return 1
      ;;
    *)
      echo "Error: failed to parse findings JSON while resolving short id '$prefix'" >&2
      return 1
      ;;
  esac
}

main() {
  local -a args=("$@")
  local -a prefix_args=()
  local idx=0
  local arg_count="${#args[@]}"

  while (( idx < arg_count )); do
    if [[ "${args[idx]}" == "findings" ]]; then
      break
    fi

    prefix_args+=("${args[idx]}")
    ((idx += 1))
  done

  if (( idx + 2 < arg_count )) && [[ "${args[idx]}" == "findings" ]]; then
    local action="${args[idx + 1]}"
    local id_index=$((idx + 2))
    local candidate="${args[id_index]}"

    if [[ "$action" =~ ^(get|update|delete)$ ]] && [[ "$candidate" != -* ]] && is_short_finding_id "$candidate"; then
      args[id_index]="$(resolve_finding_id "$candidate" "${prefix_args[@]}")"
    fi
  fi

  exec "$REAL_BIN" "${args[@]}"
}

main "$@"
EOF
  chmod +x "${wrapper_path}"

  python3 - "$wrapper_path" "$real_bin_path" <<'PY'
from pathlib import Path
import sys

wrapper = Path(sys.argv[1])
real_bin = Path(sys.argv[2])
wrapper.write_text(wrapper.read_text().replace("__REAL_BIN__", str(real_bin)))
PY
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

  if command -v tolmo >/dev/null 2>&1; then
    INSTALLED_BIN="$(command -v tolmo)"
    INSTALLED_DIR="$(dirname "$INSTALLED_BIN")"
    REAL_BIN_NAME="tolmo-real"

    echo "Installing shorthand-ID compatibility wrapper..."
    sudo mv "$INSTALLED_BIN" "${INSTALLED_DIR}/${REAL_BIN_NAME}"
    TMP_WRAPPER="${TMPDIR}/tolmo-wrapper"
    install_wrapper "$TMPDIR" "$REAL_BIN_NAME"
    mv "${TMPDIR}/tolmo" "$TMP_WRAPPER"
    sudo cp "$TMP_WRAPPER" "${INSTALLED_DIR}/tolmo"
    sudo chmod +x "${INSTALLED_DIR}/tolmo"
  fi

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
  cp "${TMPDIR}/tolmo" "${INSTALL_DIR}/tolmo-real"
  chmod +x "${INSTALL_DIR}/tolmo-real"
  install_wrapper "$INSTALL_DIR" "tolmo-real"
else
  echo "Installing to ${INSTALL_DIR} (requires sudo)..."
  sudo cp "${TMPDIR}/tolmo" "${INSTALL_DIR}/tolmo-real"
  sudo chmod +x "${INSTALL_DIR}/tolmo-real"
  TMP_REAL_LINK_NAME="tolmo-real"
  install_wrapper "$TMPDIR" "$TMP_REAL_LINK_NAME"
  sudo cp "${TMPDIR}/tolmo" "${INSTALL_DIR}/tolmo"
  sudo chmod +x "${INSTALL_DIR}/tolmo"
fi

echo "Installed successfully!"
"${INSTALL_DIR}/tolmo" --version
