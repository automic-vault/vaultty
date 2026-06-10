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
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
ENV_HELPER="$HELPERS_DIR/vaultty-env"
GHOSTTY_PROBE="$HELPERS_DIR/vaultty-ghostty-probe"
GHOSTTY_DYLIB="$FRAMEWORKS_DIR/libghostty-vt.dylib"
GHOSTTY_BRIDGE_OBJECT="$BUILD_DIR/GhosttyOscBridge.o"
ICON_SOURCE="$ROOT_DIR/assets/Icon@2x.png"
ICONSET_DIR="$BUILD_DIR/$APP_NAME.iconset"
FIG_AUTOCOMPLETE_DIR="$ROOT_DIR/target/vendor/fig-autocomplete/package"

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
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
ENV_HELPER="$HELPERS_DIR/vaultty-env"
GHOSTTY_PROBE="$HELPERS_DIR/vaultty-ghostty-probe"
GHOSTTY_DYLIB="$FRAMEWORKS_DIR/libghostty-vt.dylib"
GHOSTTY_BRIDGE_OBJECT="$BUILD_DIR/GhosttyOscBridge.o"
ICON_SOURCE="$ROOT_DIR/assets/Icon@2x.png"
ICONSET_DIR="$BUILD_DIR/$APP_NAME.iconset"

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

app_version() {
  local pkgid version
  pkgid="$(cargo pkgid --manifest-path "$ROOT_DIR/Cargo.toml")"
  version="${pkgid##*#}"
  printf '%s\n' "${version##*@}"
}

app_build_number() {
  local count
  if count="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)" &&
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    printf '%s\n' "$count"
  else
    printf '1\n'
  fi
}

render_info_plist() {
  local version build_number escaped_version escaped_build_number
  version="${APP_VERSION:-$(app_version)}"
  build_number="${APP_BUILD_NUMBER:-$(app_build_number)}"
  escaped_version="$(printf '%s' "$version" | sed 's/[\/&\\]/\\&/g')"
  escaped_build_number="$(printf '%s' "$build_number" | sed 's/[\/&\\]/\\&/g')"

  sed \
    -e "s/@APP_VERSION@/$escaped_version/g" \
    -e "s/@APP_BUILD_NUMBER@/$escaped_build_number/g" \
    "$ROOT_DIR/src/app/Info.plist.in" >"$CONTENTS_DIR/Info.plist"
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

codesign_runtime() {
  local timestamp_args=(--timestamp)
  if [[ "$IDENTITY" == "-" ]]; then
    timestamp_args=()
  fi
  codesign --force --options runtime "${timestamp_args[@]}" --sign "$IDENTITY" "$@"
}

verify_signature() {
  local path="$1"
  codesign --verify --strict --verbose=2 "$path"
}

bundle_icon() {
  if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "App icon not found: $ICON_SOURCE" >&2
    exit 1
  fi

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/$APP_NAME.icns"
}

bundle_completions() {
  if [[ ! -d "$FIG_AUTOCOMPLETE_DIR/build" ]]; then
    "$ROOT_DIR/scripts/fetch-fig-autocomplete.sh" >/dev/null
  fi
  if [[ ! -d "$FIG_AUTOCOMPLETE_DIR/build" ]]; then
    echo "Fig autocomplete specs not found. Run scripts/fetch-fig-autocomplete.sh." >&2
    exit 1
  fi

  rm -rf "$RESOURCES_DIR/completions"
  mkdir -p "$RESOURCES_DIR/completions/fig"
  cp -R "$FIG_AUTOCOMPLETE_DIR/build" "$RESOURCES_DIR/completions/fig/build"
  cp "$FIG_AUTOCOMPLETE_DIR/package.json" "$RESOURCES_DIR/completions/fig/package.json"
  cp "$FIG_AUTOCOMPLETE_DIR/LICENSE" "$RESOURCES_DIR/completions/fig/LICENSE"
  cp "$FIG_AUTOCOMPLETE_DIR/README.md" "$RESOURCES_DIR/completions/fig/README.md"
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
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$FRAMEWORKS_DIR"
render_info_plist
cp "$RUST_BIN_DIR/vaultty-env" "$ENV_HELPER"
bundle_icon
bundle_completions

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
    cp "$GHOSTTY_LIB" "$GHOSTTY_DYLIB"
    GHOSTTY_SWIFT_LINK_ARGS=(
      -L "$FRAMEWORKS_DIR"
      -lghostty-vt
      -Xlinker -rpath
      -Xlinker @executable_path/../Frameworks
    )
    GHOSTTY_BRIDGE_FLAGS=(-DVAULTTY_WITH_GHOSTTY=1 -I"$GHOSTTY_INCLUDE")
    clang \
      -Os \
      -target "arm64-apple-macos$MIN_MACOS_VERSION" \
      -I"$GHOSTTY_INCLUDE" \
      "$ROOT_DIR/src/ghostty_probe/main.c" \
      -L"$FRAMEWORKS_DIR" \
      -lghostty-vt \
      -Wl,-rpath,@loader_path/../Frameworks \
      -o "$GHOSTTY_PROBE"
  else
    clang \
      -Os \
      -target "arm64-apple-macos$MIN_MACOS_VERSION" \
      -I"$GHOSTTY_INCLUDE" \
      "$ROOT_DIR/src/ghostty_probe/main.c" \
      "$GHOSTTY_LIB" \
      -o "$GHOSTTY_PROBE"
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
  -framework JavaScriptCore \
  "$ROOT_DIR/src/app/main.swift" \
  "$ROOT_DIR/src/app/PtySession.swift" \
  "$ROOT_DIR/src/app/Ansi.swift" \
  "$ROOT_DIR/src/app/Completion.swift" \
  "$ROOT_DIR/src/app/TerminalViewController.swift" \
  "$GHOSTTY_BRIDGE_OBJECT" \
  "${GHOSTTY_SWIFT_LINK_ARGS[@]}" \
  -o "$EXECUTABLE"

echo "Signing with $IDENTITY"
codesign_runtime \
  --identifier "$ENV_HELPER_ID" \
  "$ENV_HELPER"
verify_signature "$ENV_HELPER"
if [[ -f "$GHOSTTY_DYLIB" ]]; then
  codesign_runtime "$GHOSTTY_DYLIB"
  verify_signature "$GHOSTTY_DYLIB"
fi
if [[ -x "$GHOSTTY_PROBE" ]]; then
  codesign_runtime \
    --identifier "$GHOSTTY_PROBE_ID" \
    "$GHOSTTY_PROBE"
  verify_signature "$GHOSTTY_PROBE"
fi
codesign_runtime \
  --entitlements "$ROOT_DIR/src/app/vaultty.entitlements" \
  --identifier "$APP_BUNDLE_ID" \
  "$APP_DIR"
verify_signature "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
