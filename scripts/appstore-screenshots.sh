#!/usr/bin/env bash
#
# appstore-screenshots.sh — capture clean App Store Connect screenshots.
#
# Boots the required simulators, overrides the status bar (9:41 clock, full
# battery, full signal — the classic Apple "hero" bar), then walks you through
# capturing each screen interactively. Saves PNGs at the exact pixel sizes
# App Store Connect wants:
#
#   iPhone 17 Pro Max  (6.9")  → 1320 × 2868   [required iPhone size]
#   iPad Pro 13-inch (M5)      → 2064 × 2752   [required iPad size]
#
# Each set covers all smaller devices in its family, so these two are all
# Apple requires.
#
# Usage:
#   scripts/appstore-screenshots.sh            # both devices
#   scripts/appstore-screenshots.sh iphone     # iPhone only
#   scripts/appstore-screenshots.sh ipad       # iPad only
#
# Screenshots land in ~/Desktop/JetLedger-Screenshots/
#
set -euo pipefail

IPHONE_NAME="iPhone 17 Pro Max"
IPAD_NAME="iPad Pro 13-inch (M5)"
OUT_DIR="${HOME}/Desktop/JetLedger-Screenshots"

# Resolve a booted-or-shutdown simulator UDID by exact device name.
# Devices exist under multiple runtimes, so we take the first match.
resolve_udid() {
  xcrun simctl list devices available \
    | grep -F "$1 (" \
    | head -1 \
    | grep -oiE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
}

apply_status_bar() {
  local udid="$1"
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --operatorName "" >/dev/null 2>&1 || {
      echo "   (status bar override failed — is the device booted?)" >&2
    }
}

capture() {
  local udid="$1" label="$2" i=1 ans file
  echo
  echo "   Rotate / navigate the simulator to each screen you want."
  echo "   Press Enter to capture, or type 'q' then Enter to move on."
  while true; do
    printf "   [%s] capture #%02d  (Enter = shoot, q = done): " "$label" "$i"
    read -r ans
    [[ "$ans" == "q" || "$ans" == "Q" ]] && break
    file="$(printf '%s/%s-%02d.png' "$OUT_DIR" "$label" "$i")"
    xcrun simctl io "$udid" screenshot "$file" >/dev/null 2>&1
    echo "      ✓ saved → $file"
    i=$((i + 1))
  done
}

prep_and_capture() {
  local name="$1" label="$2" udid
  udid="$(resolve_udid "$name")"
  if [[ -z "$udid" ]]; then
    echo "!! Could not find simulator: $name" >&2
    echo "   Run: xcrun simctl list devices available | grep -i '${label}'" >&2
    exit 1
  fi

  echo
  echo "==> $name"
  echo "    $udid"
  xcrun simctl boot "$udid" 2>/dev/null || true   # no-op if already booted
  open -a Simulator
  echo "    waiting for boot…"
  xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
  apply_status_bar "$udid"
  echo "    status bar set to 9:41 / full battery / full signal"
  capture "$udid" "$label"
  xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
}

main() {
  local target="${1:-both}"
  mkdir -p "$OUT_DIR"
  echo "Screenshots → $OUT_DIR"
  case "$target" in
    iphone) prep_and_capture "$IPHONE_NAME" "iphone" ;;
    ipad)   prep_and_capture "$IPAD_NAME"   "ipad" ;;
    both)
      prep_and_capture "$IPHONE_NAME" "iphone"
      prep_and_capture "$IPAD_NAME"   "ipad"
      ;;
    *)
      echo "usage: $0 [iphone|ipad|both]" >&2
      exit 1
      ;;
  esac
  echo
  echo "Done. Open the folder:  open \"$OUT_DIR\""
}

main "$@"
