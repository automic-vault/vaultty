#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vaultty"
INSTALL_DIR="/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
BUILD_ARGS=(--release)

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [--with-ghostty-vt]

Build a release Vaultty.app and replace /Applications/Vaultty.app with it.

Options:
  --with-ghostty-vt  Require target/ghostty-vt and bundle a libghostty-vt probe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-ghostty-vt)
      BUILD_ARGS+=("$1")
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

die() {
  echo "$*" >&2
  exit 1
}

run_install_command() {
  if [[ -w "$INSTALL_DIR" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

BUILT_APP="$("$ROOT_DIR/scripts/build-app.sh" "${BUILD_ARGS[@]}" | tail -n 1)"
[[ -d "$BUILT_APP" ]] || die "Release build did not produce an app bundle: $BUILT_APP"
[[ -x "$BUILT_APP/Contents/MacOS/$APP_NAME" ]] || die "Release build is missing its executable: $BUILT_APP"
[[ -d "$INSTALL_DIR" ]] || die "Install directory does not exist: $INSTALL_DIR"

STAGED_APP="$INSTALL_DIR/.$APP_NAME.app.install.$$"
BACKUP_APP=""

cleanup() {
  if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
    if [[ ! -d "$TARGET_APP" ]]; then
      run_install_command mv "$BACKUP_APP" "$TARGET_APP" || true
    else
      run_install_command rm -rf "$BACKUP_APP" || true
    fi
  fi
  if [[ -d "$STAGED_APP" ]]; then
    run_install_command rm -rf "$STAGED_APP" || true
  fi
}
trap cleanup EXIT

run_install_command rm -rf "$STAGED_APP"
run_install_command ditto "$BUILT_APP" "$STAGED_APP"

if [[ -d "$TARGET_APP" ]]; then
  BACKUP_APP="$INSTALL_DIR/.$APP_NAME.app.previous.$$"
  run_install_command mv "$TARGET_APP" "$BACKUP_APP"
fi

run_install_command mv "$STAGED_APP" "$TARGET_APP"

if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
  run_install_command rm -rf "$BACKUP_APP"
  BACKUP_APP=""
fi

trap - EXIT
echo "$TARGET_APP"
