"""Opt-in default file manager and local forwarding to the running window."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

from PySide6.QtCore import QUrl
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import QMessageBox


def host_environment():
    env = os.environ.copy()
    if 'LD_LIBRARY_PATH_ORIG' in env:
        env['LD_LIBRARY_PATH'] = env.pop('LD_LIBRARY_PATH_ORIG')
    else:
        env.pop('LD_LIBRARY_PATH', None)
    env.pop('QT_PLUGIN_PATH', None)
    env.pop('QT_QPA_PLATFORM_PLUGIN_PATH', None)
    return env


def folder_argument(value):
    if value.startswith('file:'):
        url = QUrl(value)
        if not url.isLocalFile() or url.host() not in ('', 'localhost'):
            raise ValueError('Only local folder URLs are supported.')
        value = url.toLocalFile()
    elif '://' in value:
        raise ValueError('Use Connections for network addresses.')
    return Path(os.path.abspath(os.path.expanduser(value)))


def socket_name(state):
    return 'opencommander-' + hashlib.sha256(os.fsencode(state.resolve())).hexdigest()[:24]


def forward(name, folder):
    client = QLocalSocket()
    client.connectToServer(name)
    if not client.waitForConnected(1500):
        return False
    client.write(json.dumps({'folder': str(folder) if folder else None}).encode() + b'\n')
    client.flush()
    if not client.waitForReadyRead(2000):
        return False
    return bytes(client.readAll()) == b'OK\n'


def listen(window, name):
    QLocalServer.removeServer(name)  # Caller already holds the profile lock.
    server = QLocalServer(window)
    server.setSocketOptions(QLocalServer.UserAccessOption)
    def connected():
        while server.hasPendingConnections():
            client = server.nextPendingConnection()
            buffer = bytearray()
            def read(client=client, buffer=buffer):
                buffer.extend(bytes(client.readAll()))
                if len(buffer) > 65536:
                    client.disconnectFromServer()
                    return
                if b'\n' not in buffer:
                    return
                try:
                    request = json.loads(buffer.split(b'\n')[0])
                    if request.get('folder'):
                        window.active.navigate(folder_argument(request['folder']))
                    window.showNormal()
                    window.raise_()
                    window.activateWindow()
                    client.write(b'OK\n')
                    client.flush()
                except (ValueError, TypeError, AttributeError):
                    client.write(b'ERROR\n')
                client.disconnectFromServer()
            client.readyRead.connect(read)
            client.disconnected.connect(client.deleteLater)
            if client.bytesAvailable():
                read()
    server.newConnection.connect(connected)
    if not server.listen(name):
        raise RuntimeError(server.errorString())
    return server


def ask_default(window):
    settings = window.settings
    if settings.value('default_manager_prompted', False, type=bool):
        return
    de = window.language == 'de'
    title = 'Standard-Dateimanager' if de else 'Default file manager'
    question = ('OpenCommander als Standard-Dateimanager verwenden?\n\nOrdner werden dann mit OpenCommander geöffnet.'
                if de else 'Use OpenCommander as the default file manager?\n\nFolders will open in OpenCommander.')
    answer = QMessageBox.question(window, title, question,
                                  QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
    if answer == QMessageBox.Yes:
        try:
            data = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
            if not (data / 'applications/opencommander.desktop').is_file():
                raise RuntimeError('Bitte zuerst install-local.sh im Anwendungspaket ausführen.' if de
                                   else 'Run install-local.sh in the application package first.')
            subprocess.run(['xdg-mime', 'default', 'opencommander.desktop', 'inode/directory'],
                           check=True, timeout=10, env=host_environment(), capture_output=True)
            # GIO follows GNOME's real association lookup. Some xdg-mime versions
            # incorrectly reject a valid quoted Exec path during their query.
            query = ['/usr/bin/python3', '-c',
                     'from gi.repository import Gio; '
                     'app = Gio.AppInfo.get_default_for_type("inode/directory", False); '
                     'print(app.get_id() if app else "")']
            try:
                result = subprocess.run(query, check=True, timeout=10, env=host_environment(),
                                        capture_output=True, text=True)
            except (OSError, subprocess.SubprocessError):
                result = subprocess.run(['xdg-mime', 'query', 'default', 'inode/directory'],
                                        check=True, timeout=10, env=host_environment(),
                                        capture_output=True, text=True)
            if result.stdout.strip() != 'opencommander.desktop':
                raise RuntimeError('Die Zuordnung wurde nicht übernommen.' if de else 'Association was not applied.')
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            QMessageBox.warning(window, title, str(error))
            return
    settings.setValue('default_manager_prompted', True)
    settings.sync()
