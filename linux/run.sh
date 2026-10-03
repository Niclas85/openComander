#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$task_root/.venv/bin/python" ]; then
    python3 -m venv "$task_root/.venv"
fi
if ! "$task_root/.venv/bin/python" -c "from PySide6 import QtWidgets, QtMultimedia, QtMultimediaWidgets" >/dev/null 2>&1; then
    "$task_root/.venv/bin/python" -m pip install --no-cache-dir -r "$task_root/requirements.txt"
fi
exec "$task_root/.venv/bin/python" "$task_root/launcher.py" "$@"
