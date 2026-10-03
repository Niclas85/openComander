#!/bin/sh
# Register this portable directory in the current user's application menu.
# Keep the directory in place after installation; rerun this script after moving it.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$task_root/opencommander" ]; then
    printf '%s\n' 'Run this script from the extracted portable package.' >&2
    exit 1
fi
python3 - "$task_root" <<'PY'
from pathlib import Path
import os, sys, re
root = Path(sys.argv[1])
if any(ord(character) < 32 for character in str(root)):
    raise SystemExit('The package path must not contain control characters.')
data = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
applications = data / 'applications'
applications.mkdir(parents=True, exist_ok=True)
# Desktop Entry Exec has its own escaping rules, independent of shell quoting.
def exec_quote(value):
    if re.fullmatch(r'[A-Za-z0-9_./-]+', value):
        return value
    return '"' + value.replace('\\', '\\\\\\\\').replace('"', '\\\\"').replace('`', '\\\\`').replace('$', '\\\\$').replace('%', '%%') + '"'
icon = root / '_internal/opencommander/assets/opencommander.png'
entry = '[Desktop Entry]\nType=Application\nName=OpenCommander\nComment=Two-pane file manager\n'
entry += 'Exec=' + exec_quote(str(root / 'opencommander')) + ' %u\n'
entry += 'Icon=' + str(icon) + '\nTerminal=false\nMimeType=inode/directory;\nCategories=System;FileManager;\nStartupNotify=true\n'
path = applications / 'opencommander.desktop'
path.write_text(entry)
print('Desktop launcher:', path)
PY
