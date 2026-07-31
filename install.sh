#!/usr/bin/env bash
# One-command setup for filler-killer. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "filler-killer setup"

# 1. uv (fast Python package manager) — install if missing
if ! command -v uv >/dev/null 2>&1; then
  echo "installing uv (https://docs.astral.sh/uv) ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
echo "uv: $(uv --version)"

# 2. Virtualenv + dependencies (realtime extras only make sense on macOS)
uv venv --allow-existing
if [ "$(uname -s)" = "Darwin" ]; then
  uv pip install -q -e ".[realtime]"
else
  uv pip install -q -e .
  echo "note: non-macOS — installing reflection-only (fk listen needs a Mac)"
fi

# 3. Diagnose the environment and say exactly what (if anything) to fix
echo
uv run fk doctor || true

echo
bold "Setup complete. Daily use:"
echo "  uv run fk dashboard    # sync Granola + open your filler dashboard"
echo "  uv run fk listen       # live menu bar counter during a call"
