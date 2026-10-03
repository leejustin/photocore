#!/bin/zsh
# Runs photocore-server for trying Bound's web pages locally: a scratch data
# folder, the no-charge test checkout and test printer, the offline diary
# writer, and emails written to <data>/worker-runs/trips/outbox.
#   Scripts/dev-server.sh            # http://127.0.0.1:8799, token dev-token
#   PORT=9000 DATA=/tmp/bound Scripts/dev-server.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8799}"
DATA="${DATA:-$PWD/.build/dev-server-data}"
mkdir -p "$DATA"
swift build --product photocore-server 2>&1 | grep -E "error|Compiling|Build complete" || true
export PHOTO_ENGINE_TOKEN="${PHOTO_ENGINE_TOKEN:-dev-token}"
export PHOTO_ENGINE_PORT="$PORT"
export PHOTOCORE_DATA_DIR="$DATA"
export PHOTO_ENGINE_ALLOWED_ROOTS="$DATA"
export PHOTOCORE_DEV_CHECKOUT=1
export PHOTOCORE_OFFLINE="${PHOTOCORE_OFFLINE:-1}"
export PHOTOCORE_WRITER="${PHOTOCORE_WRITER:-offline}"
exec .build/debug/photocore-server
