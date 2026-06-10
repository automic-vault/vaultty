#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ARGS=(--debug)
APP_ARGS=()

usage() {
  cat <<'EOF'
Usage: scripts/run.sh [--debug|--release] [--with-ghostty-vt] [-- APP_ARGS...]

Build Vaultty and run the app executable directly.

Examples:
  scripts/run.sh
  scripts/run.sh -- --self-test 'man ls'
  scripts/run.sh --release --with-ghostty-vt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      BUILD_ARGS=(--debug)
      shift
      ;;
    --release)
      BUILD_ARGS=(--release)
      shift
      ;;
    --with-ghostty-vt)
      BUILD_ARGS+=("$1")
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      APP_ARGS=("$@")
      break
      ;;
    *)
      APP_ARGS+=("$1")
      shift
      ;;
  esac
done

APP_DIR="$("$ROOT_DIR/scripts/build-app.sh" "${BUILD_ARGS[@]}" | tail -n 1)"
EXECUTABLE="$APP_DIR/Contents/MacOS/Vaultty"

exec "$EXECUTABLE" "${APP_ARGS[@]}"
