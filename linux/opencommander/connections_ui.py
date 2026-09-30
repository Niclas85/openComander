from pathlib import Path
from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout, QLabel, QListWidget,
                              QListWidgetItem, QPushButton, QLineEdit, QMessageBox)
from . import integrations


class ConnectionsDialog(QDialog):
    def __init__(self, main):
        super().__init__(main)
        self.main = main
        self.pending = False
        self.setWindowTitle(self.t('Verbindungen', 'Connections'))
        self.resize(780, 480)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(self.t('USB, Laufwerke, Netzwerk und Cloud', 'USB, drives, network and cloud')))
        self.items = QListWidget()
        self.items.setSpacing(5)
        layout.addWidget(self.items)
        self.items.itemDoubleClicked.connect(lambda _: self.open_selected())
        row = QHBoxLayout()
        for de, en, callback in [('Öffnen / Einbinden', 'Open / Mount', self.open_selected),
                                 ('Trennen / Auswerfen', 'Disconnect / Eject', self.disconnect),
                                 ('Aktualisieren', 'Refresh', self.refresh)]:
            button = QPushButton(self.t(de, en))
            button.clicked.connect(callback)
            row.addWidget(button)
        layout.addLayout(row)
        self.address = QLineEdit()
        self.address.setPlaceholderText('smb://server/freigabe   •   sftp://server   •   davs://server/pfad')
        layout.addWidget(self.address)
        connect = QPushButton(self.t('Netzlaufwerk verbinden', 'Connect network location'))
        connect.clicked.connect(self.connect_network)
        layout.addWidget(connect)
        accounts = QPushButton(self.t('Google Drive / OneDrive – Konto hinzufügen', 'Google Drive / OneDrive – Add account'))
        accounts.clicked.connect(self.accounts)
        layout.addWidget(accounts)
        note = QLabel(self.t('Cloud-Anmeldung erfolgt in den Linux-Online-Konten. Datei-Zugriff dort aktivieren.\n'
                            'Vorhandene GVFS- und rclone-Mounts erscheinen automatisch.\n'
                            'Dropbox: lokalen Sync-Ordner verwenden. iCloud: separat eingerichteten Mount verwenden.',
                            'Sign in through Linux Online Accounts and enable file access there.\n'
                            'Existing GVFS and rclone mounts appear automatically.\n'
                            'Dropbox: use the local sync folder. iCloud: use a separately configured mount.'))
        note.setWordWrap(True)
        layout.addWidget(note)
        self.status = QLabel()
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(5000)
        self.refresh()

    def t(self, de, en):
        return de if self.main.language == 'de' else en

    def work(self, callback, after=None):
        if self.pending:
            return
        from .ui import Task
        self.pending = True
        self.status.setText(self.t('Bitte warten …', 'Please wait …'))
        task = Task(callback)
        self.main.tasks.add(task)
        def done(value, error):
            self.main.tasks.discard(task)
            self.pending = False
            self.status.setText(str(error) if error else '')
            if not error and after:
                after(value)
        task.signals.result.connect(done)
        self.main.pool.start(task)

    def refresh(self):
        self.work(integrations.invoke, self.populate)

    def populate(self, locations):
        previous = self.selected()
        self.items.clear()
        for location in locations:
            suffix = location['path'] or self.t('nicht eingebunden', 'not mounted')
            item = QListWidgetItem(f"{location['name']}   [{location['kind']}]\n{suffix}")
            item.setData(Qt.UserRole, location)
            self.items.addItem(item)
            if previous and previous['id'] == location['id']:
                self.items.setCurrentItem(item)
        self.main.integration_locations = locations
        self.main.update_places()

    def selected(self):
        item = self.items.currentItem()
        return item.data(Qt.UserRole) if item else None

    def open_selected(self):
        selected = self.selected()
        if not selected or self.pending:
            return
        if selected['mounted']:
            if selected['path']:
                self.main.active.navigate(Path(selected['path']))
            else:
                self.status.setText(self.t('Lokaler GVFS-Pfad fehlt. Bitte gvfs-fuse installieren und erneut anmelden.',
                                          'No local GVFS path. Install gvfs-fuse and sign in again.'))
        else:
            self.work(lambda: integrations.invoke('mount', selected['id']), self.populate)

    def connect_network(self):
        try:
            uri = integrations.validate_uri(self.address.text())
        except ValueError as error:
            self.status.setText(str(error))
            return
        self.work(lambda: integrations.invoke('connect', uri), self.populate)

    def disconnect(self):
        selected = self.selected()
        if not selected or self.pending:
            return
        if self.main.busy:
            self.status.setText(self.t('Zuerst laufenden Dateivorgang abschließen.', 'Wait for the current file operation.'))
            return
        if not (selected['eject'] or selected['unmount']):
            return
        if QMessageBox.question(self, self.windowTitle(), self.t('Verbindung trennen: ', 'Disconnect: ') + selected['name']) != QMessageBox.Yes:
            return
        # Release directory watches before asking the desktop to unmount safely.
        if selected['path']:
            root = Path(selected['path'])
            for pane in self.main.panes:
                if pane.directory == root or root in pane.directory.parents:
                    pane.navigate(Path.home())
        self.main.busy = True
        def action():
            return integrations.invoke('eject' if selected['eject'] else 'unmount', selected['id'])
        # Busy must be cleared for both success and failure.
        from .ui import Task
        task = Task(action)
        self.pending = True
        self.main.tasks.add(task)
        def done(value, error):
            self.main.busy = False
            self.pending = False
            self.main.tasks.discard(task)
            self.status.setText(str(error) if error else '')
            if not error:
                self.populate(value)
        task.signals.result.connect(done)
        self.main.pool.start(task)

    def accounts(self):
        try:
            integrations.open_accounts()
        except OSError as error:
            self.status.setText(str(error))

    def closeEvent(self, event):
        if self.pending:
            event.ignore()
        else:
            self.timer.stop()
            super().closeEvent(event)

    def reject(self):
        if not self.pending:
            self.timer.stop()
            super().reject()
