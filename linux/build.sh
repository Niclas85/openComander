#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_work=${OPENCOMMANDER_BUILD_ROOT:-"$task_root/build"}
task_dist=${OPENCOMMANDER_DIST_ROOT:-"$task_root/dist"}
if [ ! -x "$task_root/.venv/bin/python" ]; then
    python3 -m venv "$task_root/.venv"
fi
"$task_root/.venv/bin/python" -m pip install --no-cache-dir -r "$task_root/requirements-dev.txt"
mkdir -p "$task_work" "$task_dist" "$task_root/artifacts"
# Qt 6's X11 platform plugin needs this small Ubuntu runtime library.
# Download/extract it locally; never install a system package or request root.
task_runtime="$task_work/xcb-runtime"
mkdir -p "$task_runtime"
(cd "$task_runtime" && apt-get download libxcb-cursor0)
for task_deb in "$task_runtime"/libxcb-cursor0_*.deb; do
    dpkg-deb -x "$task_deb" "$task_runtime/root"
done
task_cursor=$("$task_root/.venv/bin/python" -c 'import glob,sys; print(glob.glob(sys.argv[1]+"/root/usr/lib/*/libxcb-cursor.so.0")[0])' "$task_runtime")
"$task_root/.venv/bin/python" -m PyInstaller --noconfirm --clean --onedir \
    --name opencommander --workpath "$task_work" --distpath "$task_dist" \
    --specpath "$task_work" --paths "$task_root" \
    --add-data "$task_root/opencommander/assets:opencommander/assets" \
    --add-data "$task_root/opencommander/gio_bridge.py:opencommander" \
    --copy-metadata PySide6-Addons --copy-metadata PySide6-Essentials --copy-metadata shiboken6 \
    --add-binary "$task_cursor:." \
    "$task_root/launcher.py"
task_bundle="$task_dist/opencommander"
cp "$task_root/README.md" "$task_root/CHANGELOG.md" "$task_root/THIRD-PARTY.md" "$task_root/install-local.sh" "$task_bundle/"
cp "$task_root/../LICENSE" "$task_bundle/LICENSE"
cp -R "$task_root/licenses" "$task_bundle/licenses"
cp "$task_runtime/root/usr/share/doc/libxcb-cursor0/copyright" "$task_bundle/licenses/xcb-cursor-copyright"
mkdir -p "$task_bundle/source/opencommander"
cp "$task_root"/opencommander/*.py "$task_bundle/source/opencommander/"
cp -R "$task_root/opencommander/assets" "$task_bundle/source/opencommander/assets"
cp "$task_root/launcher.py" "$task_root/requirements.txt" "$task_bundle/source/"
QT_QPA_PLATFORM=offscreen "$task_bundle/opencommander" --smoke-test
(task_arch=$(uname -m); cd "$task_dist"; tar -czf "$task_root/artifacts/OpenCommander-linux-$task_arch.tar.gz" opencommander)
(cd "$task_root/artifacts"; sha256sum OpenCommander-linux-*.tar.gz > SHA256SUMS)
printf 'Linux application: %s\n' "$task_bundle/opencommander"
