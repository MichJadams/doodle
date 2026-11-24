#!/usr/bin/env bash
# Doodle IDE build script (Linux / Steam Deck)
# Usage: ./build.sh [run|replay [trace] [options]|test|release]
# Debug builds record every run to bin/traces (docs/TRACE.md); release builds don't.
set -euo pipefail

SRC="src/app"
OUT="bin/doodle"
mkdir -p bin

case "${1:-}" in
  test)
    odin test src/model
    odin test src/stt
    ;;
  release)
    odin build "$SRC" -out:"$OUT" -o:speed -no-bounds-check -define:DOODLE_TRACE=false # no action recording
    ;;
  run)
    odin build "$SRC" -out:"$OUT" -debug
    exec "$OUT"
    ;;
  replay)
    odin build "$SRC" -out:"$OUT" -debug
    shift
    exec "$OUT" --replay "${1:-last}" "${@:2}"
    ;;
  *)
    odin build "$SRC" -out:"$OUT" -debug
    ;;
esac
