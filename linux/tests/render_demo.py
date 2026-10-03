"""Generate review screenshots using synthetic files only."""
from pathlib import Path
import sys
import tempfile
import time
from PySide6.QtCore import Qt
from PySide6.QtGui import QImage, QColor, QPainter
from PySide6.QtWidgets import QApplication
from opencommander.ui import MainWindow

app = QApplication([])
app.setStyle('Fusion')
output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='OpenCommander-Demo-') as temp:
    root = Path(temp)
    left, right = root / 'Projekte', root / 'Austausch'
    left.mkdir()
    right.mkdir()
    for name in ('Dokumente', 'Bilder', 'Entwicklung', 'Archiv'):
        (left / name).mkdir()
    (left / 'Willkommen.txt').write_text('OpenCommander für Linux\nZwei Seiten. Volle Übersicht.\n')
    (left / 'Projektplan.csv').write_text('Aufgabe,Status\nLinuxversion,In Prüfung\n' * 12)
    (left / 'Notizen.md').write_text('# Projektideen\n\nDateien sicher organisieren.\n' * 8)
    (right / 'Backups').mkdir()
    (right / 'Freigaben').mkdir()
    (right / 'Liesmich.txt').write_text('Zielbereich für kopierte Dateien.\n')
    image = QImage(640, 400, QImage.Format_RGB32)
    image.fill(QColor('#284d72'))
    painter = QPainter(image)
    painter.setPen(QColor('#ffffff'))
    painter.drawText(image.rect(), Qt.AlignCenter, 'OpenCommander · Linux')
    painter.end()
    image.save(str(left / 'Vorschau.png'))
    window = MainWindow(root / 'state', left, right)
    window.language_combo.setCurrentIndex(0)
    window.show()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        app.processEvents()
        time.sleep(0.01)
    for pane in window.panes:
        pane.tree.setRootIndex(pane.tree_model.index(str(root)))
    window.panes[0].table.selectRow(4)
    window.activate(window.panes[0])
    app.processEvents()
    assert window.grab().save(str(output / 'linux-dark.png'))
    window.toggle_theme()
    app.processEvents()
    assert window.grab().save(str(output / 'linux-light.png'))
    from opencommander.filesystem import Entry
    window.open_entry(Entry('Vorschau.png', left / 'Vorschau.png', False))
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        app.processEvents()
        time.sleep(0.01)
    assert window.preview_dialog.grab().save(str(output / 'linux-media.png'))
    window.preview_dialog.close()
    window.engine.transfer([left / 'Vorschau.png'], right)
    window.engine.transfer([left / 'Notizen.md'], right)
    window.reload_history()
    window.history_dock.show()
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        app.processEvents()
        time.sleep(0.01)
    assert window.grab().save(str(output / 'linux-history.png'))
    window.connections()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        app.processEvents()
        time.sleep(0.01)
    assert window.connections_dialog.grab().save(str(output / 'linux-connections.png'))
    window.connections_dialog.close()
    window.close()
