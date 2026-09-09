#!/bin/bash
# Put the `atrium` command on your PATH. Run once.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/scripts/atrium-update"

# Prefer a location that needs no sudo. Homebrew's bin is already on PATH for
# most setups; ~/.local/bin is the fallback.
if [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then
  DEST="/opt/homebrew/bin/atrium"
elif [ -w /usr/local/bin ]; then
  DEST="/usr/local/bin/atrium"
else
  mkdir -p "$HOME/.local/bin"
  DEST="$HOME/.local/bin/atrium"
fi

ln -sf "$SRC" "$DEST"
echo "Installed: atrium -> $SRC"

if ! command -v atrium >/dev/null 2>&1; then
  echo
  echo "$(dirname "$DEST") is not on your PATH. Add it:"
  echo "    echo 'export PATH=\"$(dirname "$DEST"):\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
else
  echo
  echo "Try:  atrium status"
fi
