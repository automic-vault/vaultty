#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/target/tools"
ZIG_DIR="$TOOLS_DIR/zig-aarch64-macos-0.15.2"
TARBALL="$TOOLS_DIR/zig-0.15.2.tar.xz"
URL="https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This helper currently pins Zig 0.15.2 for arm64 macOS." >&2
  exit 1
fi

mkdir -p "$TOOLS_DIR"
if [[ ! -x "$ZIG_DIR/zig" ]]; then
  curl -fL -o "$TARBALL" "$URL"
  (
    cd "$TOOLS_DIR"
    echo "$SHA256  $(basename "$TARBALL")" | shasum -a 256 -c -
  )
  rm -rf "$ZIG_DIR"
  tar -C "$TOOLS_DIR" -xf "$TARBALL"
fi

printf '%s\n' "$ZIG_DIR/zig"
