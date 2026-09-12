#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Verwendung: $0 ADB_SERIAL_ODER_IP:PORT" >&2
  exit 2
fi

tv_address="$1"
script_dir="$(cd "$(dirname "$0")" && pwd)"
apk_path="$script_dir/OpenCommander-1.3-tv-universal.apk"

if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/platform-tools/adb" ]]; then
  adb_command="$ANDROID_HOME/platform-tools/adb"
elif command -v adb >/dev/null 2>&1; then
  adb_command="$(command -v adb)"
else
  echo "ADB wurde nicht gefunden. Installiere zuerst Android SDK Platform Tools." >&2
  exit 1
fi

if [[ ! -f "$apk_path" ]]; then
  echo "APK fehlt: $apk_path" >&2
  exit 1
fi

if ! "$adb_command" devices | cut -f1 | grep -Fxq "$tv_address"; then
  echo "Verbinde mit $tv_address ..."
  "$adb_command" connect "$tv_address"
fi

device_state="$("$adb_command" -s "$tv_address" get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "Der Fernseher ist noch nicht autorisiert. Bestaetige die RSA-Abfrage am TV und starte das Skript erneut." >&2
  exit 1
fi

echo "Installiere OpenCommander ..."
"$adb_command" -s "$tv_address" install -r "$apk_path"

echo "Pruefe den Android-TV-Launcher ..."
launcher_result="$("$adb_command" -s "$tv_address" shell cmd package query-activities \
  -a android.intent.action.MAIN \
  -c android.intent.category.LEANBACK_LAUNCHER \
  com.opencommander 2>/dev/null || true)"

if [[ "$launcher_result" != *"com.opencommander.MainActivity"* ]]; then
  echo "Installation erfolgreich, aber der Leanback-Launcher wurde vom TV nicht gemeldet." >&2
  exit 1
fi

"$adb_command" -s "$tv_address" shell am start -n com.opencommander/.MainActivity >/dev/null
echo "OpenCommander wurde installiert und gestartet."
