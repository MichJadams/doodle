#!/usr/bin/env bash
# Build whisper.cpp (whisper-cli) and download a model for Doodle's STT.
# Works on Linux / Steam Deck and in a bash shell on Windows (Git Bash / MSYS).
#
# Usage: tools/stt/setup_whisper.sh [model]
#   model defaults to base.en  (good accuracy for single words)
#   smaller/faster: tiny.en   larger/more-accurate: small.en
set -euo pipefail

MODEL="${1:-base.en}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TP="$ROOT/third_party"
WC="$TP/whisper.cpp"
mkdir -p "$TP"

echo "== Doodle STT setup =="
echo "repo:  $ROOT"
echo "model: ggml-$MODEL.bin"

# 1. clone
if [ ! -d "$WC" ]; then
  echo "-- cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WC"
fi

# 2. configure + build whisper-cli
echo "-- configuring (cmake)"
CMAKE_ARGS=(-S "$WC" -B "$WC/build" -DCMAKE_BUILD_TYPE=Release
            -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_NATIVE=ON)

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Windows: native build with the llvm-mingw clang toolchain.
    CMAKE_ARGS+=(-G "MinGW Makefiles" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
    ;;
  *)
    : # Linux/Deck: use the default system compiler + generator.
    ;;
esac

cmake "${CMAKE_ARGS[@]}"
echo "-- building whisper-cli"
cmake --build "$WC/build" --target whisper-cli --config Release -j "$(nproc 2>/dev/null || echo 4)"

# 3. download model
mkdir -p "$WC/models"
MODEL_FILE="$WC/models/ggml-$MODEL.bin"
if [ ! -f "$MODEL_FILE" ]; then
  echo "-- downloading model ggml-$MODEL.bin"
  curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin" -o "$MODEL_FILE"
fi

# 4. locate the built binary
CLI="$(find "$WC/build" -iname 'whisper-cli*' -type f | head -1 || true)"
echo
echo "== done =="
echo "whisper-cli: $CLI"
echo "model:       $MODEL_FILE"
echo
echo "Quick test:"
echo "  \"$CLI\" -m \"$MODEL_FILE\" -f \"$WC/samples/jfk.wav\" -nt"
