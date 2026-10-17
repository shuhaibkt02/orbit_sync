#!/usr/bin/env bash
set -uo pipefail

PKG="${PKG:-com.example.example}"
DEVICE="${DEVICE:-}"
SERVER="${SYNC_TEST_SERVER:-http://127.0.0.1:8080}"
MUTATIONS="${MUTATIONS:-50}"

ADB_BIN="${ADB_BIN:-$(which adb 2>/dev/null || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
FLUTTER_BIN="${FLUTTER_BIN:-$(which flutter 2>/dev/null || echo "$HOME/development/flutter/bin/flutter")}"
DART_BIN="${DART_BIN:-$(which dart 2>/dev/null || echo "$HOME/development/flutter/bin/dart")}"

# Check for attached but unauthorized devices
UNAUTH_DEVICE=$($ADB_BIN devices 2>/dev/null | grep -i "unauthorized" | head -n 1 | awk '{print $1}')
if [ -n "$UNAUTH_DEVICE" ]; then
  echo "ERROR: Device '$UNAUTH_DEVICE' is attached but unauthorized."
  echo "Please unlock your phone and tap 'Allow USB debugging' on the prompt."
  exit 1
fi

if [ -z "${DEVICE:-}" ]; then
  # Auto-select physical Android device if connected via USB
  PHYSICAL_DEVICE=$($ADB_BIN devices -l 2>/dev/null | grep -v "emulator" | grep "device " | head -n 1 | awk '{print $1}')
  if [ -n "$PHYSICAL_DEVICE" ]; then
    DEVICE="$PHYSICAL_DEVICE"
    echo "==> Auto-selected physical Android device: $DEVICE"
  fi
fi

ADB="$ADB_BIN ${DEVICE:+-s $DEVICE}"
APP_DIR="packages/offline_sync/example"
TARGET="integration_test/airplane_mode_test.dart"

SERVER_PID=""
cleanup() {
  echo "==> Cleanup: Restoring device connectivity"
  $ADB shell cmd connectivity airplane-mode disable 2>/dev/null || true
  $ADB shell svc wifi enable 2>/dev/null || true
  $ADB shell svc data enable 2>/dev/null || true
  if [ -n "$SERVER_PID" ]; then
    echo "==> Stopping local FakeSyncServer (PID $SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "==> Checking connected Android device"
if ! $ADB get-state >/dev/null 2>&1; then
  echo "ERROR: No Android device or emulator detected via $ADB_BIN."
  echo "Please connect an Android device with USB debugging or launch an emulator, then re-run."
  exit 1
fi

# Ensure local test server is available
if ! curl -fsS "$SERVER/health" >/dev/null 2>&1; then
  echo "==> Starting local FakeSyncServer on port 8080"
  $DART_BIN run tools/sync_server/bin/server.dart 8080 >/tmp/fake_sync_server.log 2>&1 &
  SERVER_PID=$!
  for attempt in $(seq 1 10); do
    if curl -fsS "$SERVER/health" >/dev/null 2>&1; then
      echo "==> FakeSyncServer is healthy and listening on $SERVER"
      break
    fi
    sleep 0.5
  done
  if ! curl -fsS "$SERVER/health" >/dev/null 2>&1; then
    echo "ERROR: FakeSyncServer failed to start on $SERVER. Logs:"
    cat /tmp/fake_sync_server.log
    exit 1
  fi
fi

# Forward host 8080 to device loopback
$ADB reverse tcp:8080 tcp:8080 2>/dev/null || true

# Determine appropriate server URL for device
DEVICE_SERIAL=$($ADB get-serialno 2>/dev/null || echo "")
if [[ "$DEVICE_SERIAL" =~ "emulator" ]]; then
  DEVICE_SERVER="http://10.0.2.2:8080"
else
  DEVICE_SERVER="http://127.0.0.1:8080"
  if ! $ADB reverse --list 2>/dev/null | grep -q "8080"; then
    echo "WARNING: 'adb reverse' rule for port 8080 not active. USB connection may need reset."
  fi
fi

echo "==> Resetting app state"
$ADB shell am force-stop "$PKG" 2>/dev/null || true

echo "==> Enabling Airplane Mode"
$ADB shell cmd connectivity airplane-mode enable
$ADB shell svc wifi disable 2>/dev/null || true
$ADB shell svc data disable 2>/dev/null || true
sleep 2

LOG_DIR="${LOG_DIR:-$HOME/.offline_sync_logs}"
mkdir -p "$LOG_DIR"

echo "==> Phase 1: Queuing $MUTATIONS mutations offline"
(cd "$APP_DIR" && $FLUTTER_BIN test --no-uninstall "$TARGET" --dart-define=SYNC_TEST_SERVER="$DEVICE_SERVER" ${DEVICE:+-d "$DEVICE"}) 2>&1 | tee "$LOG_DIR/e2e_phase1.log" || true

echo "==> Hard-killing app process via OS"
$ADB shell am force-stop "$PKG"

echo "==> Restoring network"
$ADB shell cmd connectivity airplane-mode disable
$ADB shell svc wifi enable 2>/dev/null || true
$ADB shell svc data enable 2>/dev/null || true

echo "==> Polling for active connectivity"
for i in $(seq 1 30); do
  if $ADB shell ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
    echo "==> Connectivity restored (attempt $i)"
    break
  fi
  sleep 1
done

# Re-establish reverse proxy after airplane mode disable
$ADB reverse tcp:8080 tcp:8080 2>/dev/null || true
sleep 3

echo "==> Phase 2: Verifying durability & syncing upon reconnection"
(cd "$APP_DIR" && $FLUTTER_BIN test --no-uninstall "$TARGET" --dart-define=SYNC_TEST_SERVER="$DEVICE_SERVER" ${DEVICE:+-d "$DEVICE"}) 2>&1 | tee "$LOG_DIR/e2e_phase2.log"

echo "==> Archived Phase 1 & Phase 2 logs to $LOG_DIR"

echo "==> Verifying backend server-side receipt"
if command -v curl >/dev/null 2>&1; then
  orders_json=$(curl -fsS "$SERVER/orders" 2>/dev/null || echo '{"orders":[]}')
  server_count=$(echo "$orders_json" | { grep -o '"id"' || true; } | wc -l | tr -d '[:space:]')
  echo "==> Backend received $server_count records"
  if [ "$server_count" -ge "$MUTATIONS" ]; then
    echo "==> Server-side persistence verified!"
  else
    echo "ERROR: Server reports $server_count records, expected at least $MUTATIONS."
    exit 1
  fi
fi

echo "==> E2E Airplane Mode Test Finished Successfully!"
