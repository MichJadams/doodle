#!/usr/bin/env bash
# Install a Doodle SteamOS release into ~/Applications/doodle (run on the Deck).
# Usage: tools/deck_install.sh [tag]     (default: latest non-prerelease)
#   curl -fsSL https://raw.githubusercontent.com/MichJadams/doodle/master/tools/deck_install.sh | bash
set -euo pipefail
REPO="MichJadams/doodle"
DEST="${DOODLE_DIR:-$HOME/Applications/doodle}"
if [ -n "${1:-}" ]; then
  url="https://github.com/$REPO/releases/download/$1/doodle-steamos.tar.gz"
else
  url="https://github.com/$REPO/releases/latest/download/doodle-steamos.tar.gz"
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
curl -fL --progress-bar -o "$tmp/doodle.tar.gz" "$url"
tar -xzf "$tmp/doodle.tar.gz" -C "$tmp"
[ -x "$tmp/doodle/bin/doodle" ] || { echo "bad package" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$tmp/doodle" "$DEST"
echo "Installed $(cat "$DEST/VERSION") -> $DEST/bin/doodle"
