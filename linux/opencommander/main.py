import argparse
import os
from pathlib import Path
import sys
import tempfile

from PySide6.QtCore import QLockFile, QTimer
from PySide6.QtWidgets import QApplication
from .ui import MainWindow
from . import __version__
from .desktop import ask_default, folder_argument, socket_name, forward, listen


def main():
    parser = argparse.ArgumentParser(description='OpenCommander for Linux')
    parser.add_argument('folder', nargs='?', help='Folder path or file:// URL to open')
    parser.add_argument('--version', action='version', version='OpenCommander Linux ' + __version__)
    parser.add_argument('--left', type=Path)
    parser.add_argument('--right', type=Path)
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--screenshot', type=Path)
    parser.add_argument('--smoke-test', action='store_true')
    args = parser.parse_args()
    if args.folder:
        try:
            args.left = folder_argument(args.folder)
        except ValueError as error:
            parser.error(str(error))
    fixture = tempfile.TemporaryDirectory(prefix='opencommander-smoke-') if args.smoke_test else None
    if fixture:
        root = Path(fixture.name)
        args.state_dir = args.state_dir or root / 'state'
        args.left = args.left or root / 'left'
        args.right = args.right or root / 'right'
        for directory in (args.left, args.right):
            directory.mkdir(parents=True, exist_ok=True)
    state = args.state_dir or Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'opencommander'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    app = QApplication(sys.argv[:1])
    app.setApplicationName('OpenCommander')
    app.setOrganizationName('OpenCommander')
    app.setStyle('Fusion')
    lock = QLockFile(str(state / 'session.lock'))
    if not lock.tryLock(0):
        if forward(socket_name(state), args.left):
            return 0
        print('OpenCommander is already using this profile. Please close the older version and restart.', file=sys.stderr)
        return 1
    window = MainWindow(state, args.left, args.right)
    server = listen(window, socket_name(state))
    window.show()
    if not args.smoke_test and not args.screenshot:
        QTimer.singleShot(500, lambda: ask_default(window))
    exit_status = [0]
    if args.smoke_test:
        from PySide6.QtGui import QImage, QColor
        from .filesystem import Entry
        sample = QImage(120, 80, QImage.Format_RGB32)
        sample.fill(QColor('#408acb'))
        sample_path = Path(fixture.name) / 'preview.png'
        sample.save(str(sample_path))
        window.open_entry(Entry(sample_path.name, sample_path, False))
    if args.screenshot or args.smoke_test:
        def finish():
            if args.screenshot:
                args.screenshot.parent.mkdir(parents=True, exist_ok=True)
                if not window.grab().save(str(args.screenshot)):
                    exit_status[0] = 1
            if args.smoke_test:
                if window.preview_dialog.current_image.isNull():
                    exit_status[0] = 1
                    print('FAIL: media preview did not load')
                else:
                    print('PASS: Linux desktop and media viewer started, image decoded')
                window.close()
        QTimer.singleShot(2000, finish)
    result = app.exec()
    server.close()
    lock.unlock()
    if fixture:
        fixture.cleanup()
    return result or exit_status[0]


if __name__ == '__main__':
    raise SystemExit(main())
