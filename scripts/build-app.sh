#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$HOME/src/automic-vault}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Vaultty"
APP_BUNDLE_ID="com.automicvault.vaultty"
ENV_HELPER_ID="com.automicvault.vaultty.env"
GHOSTTY_PROBE_ID="com.automicvault.vaultty.ghostty-probe"
MIN_MACOS_VERSION="26.1"
BUILD_DIR="$ROOT_DIR/target/app/$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
GHOSTTY_BRIDGE_OBJECT="$BUILD_DIR/GhosttyOscBridge.o"

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--debug|--release] [--with-ghostty-vt]

Build and codesign Vaultty.app using the Developer ID identity associated with
~/src/automic-vault.

Options:
  --with-ghostty-vt  Require target/ghostty-vt and bundle a libghostty-vt probe.
EOF
}

WITH_GHOSTTY_VT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION=debug
      shift
      ;;
    --release)
      CONFIGURATION=release
      shift
      ;;
    --with-ghostty-vt)
      WITH_GHOSTTY_VT=true
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

BUILD_DIR="$ROOT_DIR/target/app/$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
GHOSTTY_BRIDGE_OBJECT="$BUILD_DIR/GhosttyOscBridge.o"

unquote_env_value() {
  local value="$1"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "$value"
}

env_file_value() {
  local key="$1"
  local file="$VAULT_DIR/.env"
  [[ -f "$file" ]] || return 1
  awk -F= -v wanted="$key" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$file"
}

codesign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$CODESIGN_IDENTITY"
    return 0
  fi

  local team_common_name
  team_common_name="$(env_file_value TEAM_COMMON_NAME || true)"
  team_common_name="$(unquote_env_value "$team_common_name")"
  if [[ -z "$team_common_name" ]]; then
    echo "Unable to read TEAM_COMMON_NAME from $VAULT_DIR/.env" >&2
    return 1
  fi

  local identity
  identity="$(security find-identity -v -p codesigning |
    sed -n "s/.*\"\(Developer ID Application: ${team_common_name} ([^\"]*)\)\".*/\1/p" |
    head -n 1)"
  if [[ -z "$identity" ]]; then
    echo "No Developer ID Application identity found for $team_common_name" >&2
    return 1
  fi
  printf '%s' "$identity"
}

IDENTITY="$(codesign_identity)"

case "$CONFIGURATION" in
  debug)
    CARGO_FLAGS=()
    SWIFT_FLAGS=(-Onone -g)
    RUST_BIN_DIR="$ROOT_DIR/target/debug"
    ;;
  release)
    CARGO_FLAGS=(--release)
    SWIFT_FLAGS=(-O)
    RUST_BIN_DIR="$ROOT_DIR/target/release"
    ;;
  *)
    echo "Unknown configuration: $CONFIGURATION" >&2
    exit 1
    ;;
esac

echo "Building vaultty-env"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS_VERSION"
cargo build "${CARGO_FLAGS[@]}" --bin vaultty-env

echo "Building Vaultty app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/src/app/Info.plist.in" "$CONTENTS_DIR/Info.plist"
cp "$RUST_BIN_DIR/vaultty-env" "$RESOURCES_DIR/vaultty-env"

GHOSTTY_SWIFT_LINK_ARGS=()
GHOSTTY_BRIDGE_FLAGS=()

if [[ "$WITH_GHOSTTY_VT" == true ]]; then
  GHOSTTY_PREFIX="$ROOT_DIR/target/ghostty-vt"
  GHOSTTY_LIB="$(find "$GHOSTTY_PREFIX" -type f \( -name 'libghostty-vt.dylib' -o -name 'libghostty-vt.a' \) | head -n 1 || true)"
  if [[ -z "$GHOSTTY_LIB" ]]; then
    echo "libghostty-vt not found. Run scripts/build-libghostty-vt.sh first." >&2
    exit 1
  fi
  GHOSTTY_INCLUDE="$GHOSTTY_PREFIX/include"
  if [[ ! -d "$GHOSTTY_INCLUDE" ]]; then
    GHOSTTY_INCLUDE="$ROOT_DIR/target/vendor/ghostty/include"
  fi
  if [[ "$GHOSTTY_LIB" == *.dylib ]]; then
    cp "$GHOSTTY_LIB" "$RESOURCES_DIR/libghostty-vt.dylib"
    GHOSTTY_SWIFT_LINK_ARGS=(
      -L "$RESOURCES_DIR"
      -lghostty-vt
      -Xlinker -rpath
      -Xlinker @executable_path/../Resources
    )
    GHOSTTY_BRIDGE_FLAGS=(-DVAULTTY_WITH_GHOSTTY=1 -I"$GHOSTTY_INCLUDE")
    clang \
      -Os \
      -target "arm64-apple-macos$MIN_MACOS_VERSION" \
      -I"$GHOSTTY_INCLUDE" \
      "$ROOT_DIR/src/ghostty_probe/main.c" \
      -L"$RESOURCES_DIR" \
      -lghostty-vt \
      -Wl,-rpath,@loader_path \
      -o "$RESOURCES_DIR/vaultty-ghostty-probe"
  else
    clang \
      -Os \
      -target "arm64-apple-macos$MIN_MACOS_VERSION" \
      -I"$GHOSTTY_INCLUDE" \
      "$ROOT_DIR/src/ghostty_probe/main.c" \
      "$GHOSTTY_LIB" \
      -o "$RESOURCES_DIR/vaultty-ghostty-probe"
  fi
fi

clang \
  -Os \
  -target "arm64-apple-macos$MIN_MACOS_VERSION" \
  "${GHOSTTY_BRIDGE_FLAGS[@]}" \
  -c "$ROOT_DIR/src/app/GhosttyOscBridge.c" \
  -o "$GHOSTTY_BRIDGE_OBJECT"

swiftc \
  "${SWIFT_FLAGS[@]}" \
  -target "arm64-apple-macosx$MIN_MACOS_VERSION" \
  -framework AppKit \
  "$ROOT_DIR/src/app/main.swift" \
  "$ROOT_DIR/src/app/PtySession.swift" \
  "$ROOT_DIR/src/app/Ansi.swift" \
  "$ROOT_DIR/src/app/TerminalViewController.swift" \
  "$GHOSTTY_BRIDGE_OBJECT" \
  "${GHOSTTY_SWIFT_LINK_ARGS[@]}" \
  -o "$EXECUTABLE"

echo "Signing with $IDENTITY"
codesign --force --options runtime --sign "$IDENTITY" \
  --identifier "$ENV_HELPER_ID" \
  "$RESOURCES_DIR/vaultty-env"
if [[ -f "$RESOURCES_DIR/libghostty-vt.dylib" ]]; then
  codesign --force --options runtime --sign "$IDENTITY" \
    "$RESOURCES_DIR/libghostty-vt.dylib"
fi
if [[ -x "$RESOURCES_DIR/vaultty-ghostty-probe" ]]; then
  codesign --force --options runtime --sign "$IDENTITY" \
    --identifier "$GHOSTTY_PROBE_ID" \
    "$RESOURCES_DIR/vaultty-ghostty-probe"
fi
codesign --force --options runtime --sign "$IDENTITY" \
  --entitlements "$ROOT_DIR/src/app/vaultty.entitlements" \
  --identifier "$APP_BUNDLE_ID" \
  "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
