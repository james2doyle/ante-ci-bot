#!/usr/bin/env bash
set -euo pipefail

# ANTE_INSTALL_DIR is the binary location (defaults to $HOME/.ante/bin).
# It is independent of ANTE_HOME (config directory, set in review.sh).
export ANTE_INSTALL_DIR="$HOME/.ante/bin"
export PATH="$ANTE_INSTALL_DIR:$PATH"

if command -v ante >/dev/null 2>&1; then
  echo "ante already installed: $(ante --version 2>/dev/null || echo unknown)"
  exit 0
fi

curl -fsSL https://ante.run/install.sh | bash

export PATH="$ANTE_INSTALL_DIR:$PATH"
echo "ante installed: $(ante --version 2>/dev/null || echo unknown)"
