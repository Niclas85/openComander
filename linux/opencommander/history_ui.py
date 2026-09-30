"""Readable recovery history, with an explicit undo button for each operation."""
from datetime import datetime
from pathlib import Path
from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QTextEdit
from shiboken6 import isValid
from .media import media_kind, thumbnail


def describe(operation, german=True):
    lines = []
    if operation.get('inputs'):
        lines.append(('Ausgangsdateien:' if german else 'Input files:'))
        lines.extend(operation['inputs'])
        lines.append('')
    for number, record in enumerate(operation['records'], 1):
        source, destination = record['source'], record['destination']
        lines.append(f'{number}. {Path(source).name}')
        if source == destination:
            lines.append(('Pfad: ' if german else 'Path: ') + destination)
        else:
            lines.append(('Quelle: ' if german else 'Source: ') + source)
            lines.append(('Ziel: ' if german else 'Destination: ') + destination)
        if record.get('backup'):
            lines.append(('Ersetzte Datei gesichert: ' if german else 'Replaced file retained: ') + record['backup'])
        if record.get('reverted'):
            lines.append('Rücknahme teilweise ausgeführt; Wiederherstellung noch offen.' if german
                         else 'Partially undone; restoration still pending.')
        lines.append('')
    if operation.get('error'):
        lines.append(('Fehler: ' if german else 'Error: ') + operation['error'])
    return '\n'.join(lines).strip()


class HistoryCard(QWidget):
    def __init__(self, main, operation):
        super().__init__()
        self.setObjectName("historyCard")
        self.setAttribute(Qt.WA_StyledBackground)
        de = main.language == 'de'
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        header = QHBoxLayout()
        self.thumbnail_label = QLabel()
        self.thumbnail_label.setFixedSize(76, 54)
        self.thumbnail_label.setAlignment(Qt.AlignCenter)
        self.thumbnail_label.setText('↶')
        header.addWidget(self.thumbnail_label)
        title = QLabel(main.tr_key(operation['label']) + '\n' +
                       datetime.fromtimestamp(operation['time']).strftime('%d.%m.%Y · %H:%M:%S'))
        title.setWordWrap(True)
        header.addWidget(title, 1)
        layout.addLayout(header)
        records = operation['records']
        partial = operation.get('error') or any(r.get('reverted') for r in records)
        status = ('Teilweise abgeschlossen / Rücknahme offen' if de else 'Partial completion / undo pending') if partial else ('Gespeichert · Rücknahme wird geprüft' if de else 'Saved · undo requires verification')
        state = QLabel(f'{len(records)} ' + (('Eintrag' if len(records) == 1 else 'Einträge') if de else ('entry' if len(records) == 1 else 'entries')) + ' · ' + status)
        state.setWordWrap(True)
        layout.addWidget(state)
        self.details = QTextEdit()
        self.details.setReadOnly(True)
        self.details.setPlainText(describe(operation, de))
        self.details.setMinimumHeight(90)
        self.details.setMaximumHeight(160)
        layout.addWidget(self.details)
        self.undo_button = QPushButton(main.tr_key('undo'))
        self.undo_button.setToolTip(('Diesen Vorgang rückgängig machen: ' if de else 'Undo this operation: ') + main.tr_key(operation['label']))
        self.undo_button.setEnabled(not main.busy)
        self.undo_button.clicked.connect(lambda: main.undo(operation['id']))
        layout.addWidget(self.undo_button)
        self.preview_requested = False
        self.main, self.operation = main, operation

    def request_preview(self):
        if self.preview_requested:
            return
        self.preview_requested = True
        record = next((r for r in self.operation['records']
                       if media_kind(r['source']) in ('image', 'video')), None)
        if not record:
            return
        from .ui import Task
        def work():
            for path in (record['destination'], record['source']):
                try:
                    image = thumbnail(Path(path), media_kind(record['source']))
                    if not image.isNull():
                        return image
                except Exception:
                    continue
            return None
        task = Task(work)
        self.main.tasks.add(task)
        def done(image, error):
            self.main.tasks.discard(task)
            if isValid(self.thumbnail_label) and not error and image is not None:
                self.thumbnail_label.setPixmap(QPixmap.fromImage(image).scaled(QSize(76, 54), Qt.KeepAspectRatio, Qt.SmoothTransformation))
        task.signals.result.connect(done)
        self.main.thumbnails.pool.start(task)
