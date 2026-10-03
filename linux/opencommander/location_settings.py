import json
from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout, QTableWidget,
    QTableWidgetItem, QPushButton, QLabel, QFileDialog, QComboBox)


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
        language_row = QHBoxLayout()
        self.language_label = QLabel('Sprache' if self.de else 'Language')
        language_row.addWidget(self.language_label)
        self.language_combo = QComboBox()
        self.language_combo.setObjectName('SettingsLanguageDropdown')
        self.language_combo.addItem('Deutsch', 'de')
        self.language_combo.addItem('English', 'en')
        self.language_combo.setCurrentIndex(0 if self.de else 1)
        self.language_combo.currentIndexChanged.connect(self.change_language)
        language_row.addWidget(self.language_combo)
        language_row.addStretch()
        layout.addLayout(language_row)
        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(['Sichtbar', 'Name', 'Pfad'] if self.de else ['Visible', 'Name', 'Path'])
        layout.addWidget(self.table)
        self.help_label = QLabel()
        layout.addWidget(self.help_label)
        buttons = QHBoxLayout()
        self.buttons = []
        for title, callback in [('Ordner hinzufügen…' if self.de else 'Add folder…', self.add_folder),
                                ('Nur Verknüpfung entfernen' if self.de else 'Remove shortcut only', self.remove),
                                ('Fertig' if self.de else 'Done', self.accept)]:
            button = QPushButton(title)
            button.clicked.connect(callback)
            self.buttons.append(button)
            buttons.addWidget(button)
        layout.addLayout(buttons)
        self.retranslate()
        self.refresh()
        self.table.itemChanged.connect(self.save)

    def change_language(self):
        self.main.change_language(self.language_combo.currentData())
        self.de = self.main.language == 'de'
        self.retranslate()

    def retranslate(self):
        self.setWindowTitle('Einstellungen / Orte' if self.de else 'Settings / Locations')
        self.language_label.setText('Sprache' if self.de else 'Language')
        self.table.setHorizontalHeaderLabels(['Sichtbar', 'Name', 'Pfad'] if self.de else ['Visible', 'Name', 'Path'])
        self.help_label.setText('Nur Verknüpfungen werden geändert; Dateien bleiben erhalten.' if self.de
                               else 'Only shortcuts are changed; files are preserved.')
        titles = ['Ordner hinzufügen…', 'Nur Verknüpfung entfernen', 'Fertig'] if self.de else ['Add folder…', 'Remove shortcut only', 'Done']
        for button, title in zip(self.buttons, titles):
            button.setText(title)

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
