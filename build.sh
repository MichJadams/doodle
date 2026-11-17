#!/usr/bin/env bash
# Doodle IDE build script (Linux / Steam Deck)
# Usage: ./build.sh [run|test|release]
set -euo pipefail

SRC="src/app"
OUT="bin/doodle"
mkdir -p bin

case "${1:-}" in
  test)
    odin test src/buffer
    odin test src/input
    ;;
  release)
    odin build "$SRC" -out:"$OUT" -o:speed -no-bounds-check
    ;;
  run)
    odin build "$SRC" -out:"$OUT" -debug
    exec "$OUT"
    ;;
  *)
    odin build "$SRC" -out:"$OUT" -debug
    ;;
esac
