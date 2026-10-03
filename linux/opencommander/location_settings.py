import json
from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout, QTableWidget,
    QTableWidgetItem, QPushButton, QLabel, QFileDialog)


class LocationSettingsDialog(QDialog):
    def __init__(self, main, locations):
        super().__init__(main)
        self.main = main
        self.rows = [dict(row) for row in main.location_preferences]
        self.de = main.language == 'de'
        self.setWindowTitle('Einstellungen / Orte' if self.de else 'Settings / Locations')
        self.resize(720, 420)
        for name, path in locations:
            path = str(path)
            if not any(row['path'] == path for row in self.rows):
                self.rows.append(dict(name=name, path=path, enabled=True, custom=False))
        layout = QVBoxLayout(self)
        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(['Sichtbar', 'Name', 'Pfad'] if self.de else ['Visible', 'Name', 'Path'])
        layout.addWidget(self.table)
        layout.addWidget(QLabel('Nur Verknüpfungen werden geändert; Dateien bleiben erhalten.' if self.de
                               else 'Only shortcuts are changed; files are preserved.'))
        buttons = QHBoxLayout()
        for title, callback in [('Ordner hinzufügen…' if self.de else 'Add folder…', self.add_folder),
                                ('Nur Verknüpfung entfernen' if self.de else 'Remove shortcut only', self.remove),
                                ('Fertig' if self.de else 'Done', self.accept)]:
            button = QPushButton(title)
            button.clicked.connect(callback)
            buttons.addWidget(button)
        layout.addLayout(buttons)
        self.refresh()
        self.table.itemChanged.connect(self.save)

    def refresh(self):
        self.table.blockSignals(True)
        self.table.setRowCount(len(self.rows))
        for index, row in enumerate(self.rows):
            visible = QTableWidgetItem()
            visible.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable | Qt.ItemIsUserCheckable)
            visible.setCheckState(Qt.Checked if row['enabled'] else Qt.Unchecked)
            path = QTableWidgetItem(row['path'])
            path.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable)
            self.table.setItem(index, 0, visible)
            self.table.setItem(index, 1, QTableWidgetItem(row['name']))
            self.table.setItem(index, 2, path)
        self.table.resizeColumnsToContents()
        self.table.blockSignals(False)

    def save(self, *args):
        for index, row in enumerate(self.rows):
            row['enabled'] = self.table.item(index, 0).checkState() == Qt.Checked
            row['name'] = self.table.item(index, 1).text().strip() or row['path']
        self.main.location_preferences = [dict(row) for row in self.rows]
        self.main.settings.setValue('locations', json.dumps(self.rows, ensure_ascii=False))
        self.main.settings.sync()
        self.main.update_places()

    def add_folder(self):
        path = QFileDialog.getExistingDirectory(self, 'Ordner hinzufügen' if self.de else 'Add folder')
        if path and not any(row['path'] == path for row in self.rows):
            self.rows.append(dict(name=Path(path).name or path, path=path, enabled=True, custom=True))
            self.refresh(); self.save()

    def remove(self):
        index = self.table.currentRow()
        if index >= 0 and self.rows[index]['custom']:
            self.rows.pop(index)
            self.refresh(); self.save()
