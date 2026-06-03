#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
CCKIT_BIN="$ROOT_DIR/.build/release/cckit"

fail() {
  echo "install-cckit.sh: $*" >&2
  exit 1
}

if ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Swift was not found.

Install Xcode Command Line Tools, then retry:

  xcode-select --install

EOF
  exit 1
fi

if ! mkdir -p "$BIN_DIR"; then
  fail "could not create install directory: $BIN_DIR. Set PREFIX to a writable directory and retry."
fi

echo "Building cckit from $ROOT_DIR"
if ! swift build -c release --package-path "$ROOT_DIR"; then
  cat >&2 <<EOF
install-cckit.sh: release build failed.

Useful checks:
  swift --version
  xcode-select -p
  swift package resolve --package-path "$ROOT_DIR"

If Swift or the Xcode Command Line Tools are missing, install them with:
  xcode-select --install

EOF
  exit 1
fi

if [[ ! -x "$CCKIT_BIN" ]]; then
  fail "release build completed, but the expected executable was not found at $CCKIT_BIN."
fi

if ! ln -sf "$CCKIT_BIN" "$BIN_DIR/cckit"; then
  fail "could not link $BIN_DIR/cckit to $CCKIT_BIN. Check permissions for $BIN_DIR or set PREFIX to another directory."
fi

echo
echo "Installed cckit -> $BIN_DIR/cckit"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    cat <<EOF

$BIN_DIR is not currently on PATH. Add this to your shell profile:

  export PATH="$BIN_DIR:\$PATH"

For this terminal session, run:

  export PATH="$BIN_DIR:\$PATH"

EOF
    ;;
esac

if ! "$BIN_DIR/cckit" --help >/dev/null; then
  fail "installed binary did not run successfully: $BIN_DIR/cckit --help"
fi

echo "cckit is ready."
