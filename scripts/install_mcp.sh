#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="${SCOPE:-user}"
REPO="${CCKIT_REPO:-}"
CCKIT_BIN="${CCKIT_BIN:-}"
INSTALL_UV=false

usage() {
  cat <<EOF
Usage: scripts/install_mcp.sh [options]

Registers the CodeContextKit MCP shim with Claude Code.

Options:
  --repo PATH       Default repository for cckit MCP tool calls.
  --scope SCOPE     Claude Code MCP scope: user, local, or project. Default: user.
  --cckit-bin PATH  Path to the cckit executable.
  --install-uv      Install uv with Homebrew if uv is missing.
  -h, --help        Show this help.

Environment:
  CCKIT_BIN         Path to the cckit executable.
  CCKIT_REPO        Default repository for cckit MCP tool calls.
  SCOPE             Claude Code MCP scope.
EOF
}

fail() {
  echo "install_mcp.sh: $*" >&2
  exit 1
}

expand_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  if [[ "$path" != /* ]]; then
    path="$(pwd)/$path"
  fi
  printf '%s\n' "$path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || fail "--repo requires a path."
      REPO="$2"
      shift 2
      ;;
    --scope)
      [[ $# -ge 2 ]] || fail "--scope requires user, local, or project."
      SCOPE="$2"
      shift 2
      ;;
    --cckit-bin)
      [[ $# -ge 2 ]] || fail "--cckit-bin requires a path."
      CCKIT_BIN="$2"
      shift 2
      ;;
    --install-uv)
      INSTALL_UV=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "$SCOPE" in
  user|local|project) ;;
  *) fail "--scope must be user, local, or project." ;;
esac

command -v claude >/dev/null 2>&1 || fail "Claude Code CLI was not found. Install Claude Code, then retry."

if ! command -v uv >/dev/null 2>&1; then
  if [[ "$INSTALL_UV" == true ]]; then
    command -v brew >/dev/null 2>&1 || fail "uv is missing and Homebrew was not found. Install uv manually: brew install uv"
    brew install uv
  else
    fail "uv was not found. Install it with 'brew install uv' or rerun with --install-uv."
  fi
fi

if [[ -z "$CCKIT_BIN" ]]; then
  if [[ -x "$HOME/.local/bin/cckit" ]]; then
    CCKIT_BIN="$HOME/.local/bin/cckit"
  elif [[ -x "$ROOT_DIR/.build/release/cckit" ]]; then
    CCKIT_BIN="$ROOT_DIR/.build/release/cckit"
  elif command -v cckit >/dev/null 2>&1; then
    CCKIT_BIN="$(command -v cckit)"
  else
    fail "cckit was not found. Run './scripts/install-cckit.sh' or pass --cckit-bin PATH."
  fi
fi

CCKIT_BIN="$(expand_path "$CCKIT_BIN")"
[[ -x "$CCKIT_BIN" ]] || fail "cckit binary is not executable: $CCKIT_BIN"

if [[ -n "$REPO" ]]; then
  REPO="$(expand_path "$REPO")"
  [[ -d "$REPO" ]] || fail "repository path does not exist or is not a directory: $REPO"
fi

[[ -f "$ROOT_DIR/mcp/cckit_mcp.py" ]] || fail "MCP shim not found: $ROOT_DIR/mcp/cckit_mcp.py"

cmd=(claude mcp add cckit --scope "$SCOPE" --env "CCKIT_BIN=$CCKIT_BIN")
if [[ -n "$REPO" ]]; then
  cmd+=(--env "CCKIT_REPO=$REPO")
fi
cmd+=(-- uv run --script "$ROOT_DIR/mcp/cckit_mcp.py")

echo "Registering cckit MCP with Claude Code..."
"${cmd[@]}"

echo
echo "Registered cckit MCP."
echo "Verify with:"
echo "  claude mcp get cckit"
echo "  claude mcp list"
