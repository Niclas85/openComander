# Linux distribution components

OpenCommander application source is MIT-licensed; see the repository LICENSE.
The desktop uses dynamically linked PySide6 Essentials + Addons / Qt 6.11.2 and
Shiboken6 6.11.2. Their wheel metadata declares
`LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only`.
LGPL-3.0 and its referenced GPL-3.0 text are included under `licenses/`.

Upstream source, license notices and build information:

- Qt for Python: https://code.qt.io/pyside/pyside-setup.git/tree/?h=6.11.2
- Qt: https://code.qt.io/qt/qtbase.git/tree/?h=v6.11.2
- Python: https://www.python.org/downloads/source/
- PyInstaller (build tooling): https://github.com/pyinstaller/pyinstaller

The portable build uses PyInstaller's directory layout. Python and Qt libraries
remain separate in `_internal`; it does not use a one-file encrypted or sealed
bundle. The Python sources and pinned dependency requirements are also shipped
so the application can be run or rebuilt with alternative compatible libraries.
PyInstaller's bundled dependency metadata/license files are retained. No NTFS
engine or macOS extension is included in the Linux package.

The Ubuntu 24.04 portable package also includes `libxcb-cursor0`, downloaded
from the configured Ubuntu package repository during the build. Its copyright
and permission notices are shipped as `licenses/xcb-cursor-copyright`.
Package source: https://launchpad.net/ubuntu/+source/xcb-util-cursor

Qt Multimedia uses the dynamically linked FFmpeg libraries supplied by the Qt wheel.
Video thumbnail generation optionally calls the separately installed system ffmpeg;
that executable is not included in the portable package.

Qt Multimedia source: https://code.qt.io/qt/qtmultimedia.git/tree/?h=v6.11.2
FFmpeg upstream source: https://ffmpeg.org/releases/
LGPL-2.1 and GPL-2.0 license texts are also included under `licenses/`.
