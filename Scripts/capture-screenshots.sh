#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/screenshots"
DEMO="$OUT/demo-shoot"
APP="$ROOT/dist/Photocore.app"
SWIFT=/usr/bin/swift
READY="$OUT/.ready"
CONTROL="$OUT/.control"

mkdir -p "$OUT"

capture_window() {
  local name="$1"
  "$SWIFT" "$ROOT/Scripts/capture-window.swift" "$OUT/$name.png"
}

kill_app() {
  pkill -x Photocore 2>/dev/null || true
  pkill -f 'Contents/MacOS/Photocore' 2>/dev/null || true
  sleep 0.6
}

wait_ready() {
  local timeout="${1:-240}"
  for _ in $(seq 1 "$timeout"); do
    if [[ -f "$READY" ]]; then
      sleep 0.5
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for ready" >&2
  return 1
}

switch_workspace() {
  local workspace="$1"
  local name="$2"
  rm -f "$READY"
  print -r -- "workspace=${workspace}" > "$CONTROL"
  wait_ready 60 || true
  sleep 0.6
  capture_window "$name"
}

echo "Building app…"
"$ROOT/Scripts/package-app.sh" >/dev/null || true
kill_app

if [[ ! -d "$DEMO" ]] || [[ -z "$(ls -A "$DEMO" 2>/dev/null)" ]]; then
  echo "Missing demo shoot at $DEMO" >&2
  exit 1
fi

echo "→ 01-welcome"
rm -f "$READY" "$CONTROL"
open -n -a "$APP" --args --ready-file "$READY"
wait_ready 40 || true
capture_window "01-welcome"
kill_app

echo "→ 02-ready"
rm -f "$READY"
open -n -a "$APP" --args --folder "$DEMO" --ready-file "$READY"
wait_ready 40 || true
capture_window "02-ready"
kill_app

echo "→ curate once, then walk workspaces"
rm -f "$READY" "$CONTROL"
open -n -a "$APP" --args \
  --folder "$DEMO" \
  --curate \
  --workspace confirm \
  --ready-file "$READY" \
  --control-file "$CONTROL"
wait_ready 300 || true
sleep 0.8
capture_window "03-check"

switch_workspace album "04-album"
switch_workspace look "05-style"
sleep 2
capture_window "05-style"
switch_workspace deliver "06-save"
switch_workspace adjust "07-adjust"

kill_app
rm -f "$OUT/02-processing.png" "$OUT/_live.png" "$OUT/07-shortcuts.png" "$READY" "$CONTROL"
ls -la "$OUT"/0*.png
echo "Done → $OUT"
