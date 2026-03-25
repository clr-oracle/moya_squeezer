#!/bin/zsh

set -euo pipefail

CONFIG_PATH="${1:-config/local.toml}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config file not found: $CONFIG_PATH" >&2
  echo "Usage: ./scripts/squeezer.sh [path/to/config.toml]" >&2
  exit 1
fi

if ! mix deps.loadpaths >/dev/null 2>&1; then
  echo "Dependencies missing or not compiled. Running mix deps.get..."
  mix deps.get
fi

mix squeezer.run "$CONFIG_PATH"