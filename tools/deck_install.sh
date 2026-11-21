#!/usr/bin/env bash
# Install a Doodle SteamOS release into ~/Applications/doodle (run on the Deck).
# Needs an authenticated `gh` (the repo is private): drop the standalone gh
# binary in ~/bin and run `gh auth login` once.
# Usage: tools/deck_install.sh [tag]     (default: latest release)
set -euo pipefail
REPO="MichJadams/doodle"
DEST="${DOODLE_DIR:-$HOME/Applications/doodle}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

gh release download ${1:+"$1"} --repo "$REPO" --pattern 'doodle-steamos-*.tar.gz' --dir "$tmp"
tar -xzf "$tmp"/doodle-steamos-*.tar.gz -C "$tmp"
[ -x "$tmp/doodle/bin/doodle" ] || { echo "bad package" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$tmp/doodle" "$DEST"
echo "Installed $(cat "$DEST/VERSION") -> $DEST/bin/doodle"
