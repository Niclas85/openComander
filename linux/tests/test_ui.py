import time
from pathlib import Path

import pytest
from PySide6.QtCore import Qt, QUrl, QMimeData, QPointF
from PySide6.QtGui import QDropEvent
from PySide6.QtTest import QTest, QSignalSpy
from PySide6.QtWidgets import QApplication

from opencommander.ui import MainWindow


@pytest.fixture(scope='session')
def app():
    return QApplication.instance() or QApplication([])


def wait(app, predicate, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        app.processEvents()
        if predicate():
            return
        QTest.qWait(10)
    raise AssertionError('Timed out waiting for desktop event')


@pytest.fixture
def window(tmp_path, app):
    left, right = tmp_path / 'left', tmp_path / 'right'
    left.mkdir()
    right.mkdir()
    (left / 'Grüße.txt').write_text('Hello from OpenCommander')
    main = MainWindow(tmp_path / 'state', left, right)
    main.show()
    wait(app, lambda: main.panes[0].proxy.rowCount() == 1)
    yield main
    wait(app, lambda: not main.busy)
    QApplication.clipboard().clear()
    main.close()
    app.processEvents()


def test_toolbar_copy_and_undo(window, app):
    left, right = window.panes
    window.activate(left)
    left.table.selectRow(0)
    result = QSignalSpy(window.operation_finished)
    window.actions['copy'].trigger()
    wait(app, lambda: result.count() == 1)
    assert result.at(0)[0] is None
    assert (right.directory / 'Grüße.txt').exists()
    window.actions['undo'].trigger()
    wait(app, lambda: result.count() == 2)
    assert result.at(1)[0] is None
    assert not (right.directory / 'Grüße.txt').exists()


def test_clipboard_cut_paste_uses_active_destination(window, app):
    left, right = window.panes
    window.activate(left)
    left.table.selectRow(0)
    window.copy_clipboard(True)
    window.activate(right)
    window.paste_clipboard()
    wait(app, lambda: not window.busy)
    assert (right.directory / 'Grüße.txt').exists()
    assert not (left.directory / 'Grüße.txt').exists()
    assert QApplication.clipboard().mimeData() is None or not QApplication.clipboard().mimeData().hasUrls()


def test_drop_uses_selected_transfer_mode(window, app):
    left, right = window.panes
    window.mode.setCurrentIndex(1)
    mime = QMimeData()
    mime.setUrls([QUrl.fromLocalFile(str(left.directory / 'Grüße.txt'))])
    event = QDropEvent(QPointF(20, 250), Qt.CopyAction, mime, Qt.LeftButton, Qt.NoModifier)
    right.table.dropEvent(event)
    wait(app, lambda: not window.busy)
    assert event.isAccepted()
    assert event.dropAction() == Qt.CopyAction  # The engine already moved; sender must not delete again.
    assert (right.directory / 'Grüße.txt').exists()
    assert not (left.directory / 'Grüße.txt').exists()


def test_path_delete_is_text_editing_not_file_removal(window, app):
    pane = window.panes[0]
    pane.table.selectRow(0)
    window.activate(pane)
    window.actions['trash'].triggered.disconnect()
    spy = QSignalSpy(window.actions['trash'].triggered)
    pane.path_edit.setFocus()
    pane.path_edit.selectAll()
    QTest.keyClick(pane.path_edit, Qt.Key_Delete)
    app.processEvents()
    assert spy.count() == 0
    assert pane.path_edit.text() == ''
    assert (pane.directory / 'Grüße.txt').exists()


def test_filter_language_and_theme(window, app):
    pane = window.panes[0]
    pane.filter.setText('missing')
    assert pane.proxy.rowCount() == 0
    pane.filter.clear()
    assert pane.proxy.rowCount() == 1
    from opencommander.location_settings import LocationSettingsDialog
    settings = LocationSettingsDialog(window, window.known_locations)
    assert not hasattr(window, 'language_combo')
    settings.language_combo.setCurrentIndex(0)
    assert window.actions['copy'].text() == 'Kopieren'
    settings.language_combo.setCurrentIndex(1)
    assert window.actions['copy'].text() == 'Copy'
    assert settings.language_label.text() == 'Language'
    assert window.settings.value('language') == 'en'
    settings.close()
    previous = window.dark
    window.toggle_theme()
    assert window.dark != previous


def test_missing_folder_is_reported_not_shown_as_empty(window, app):
    pane = window.panes[0]
    pane.navigate(pane.directory / 'missing')
    wait(app, lambda: 'No such file' in pane.message.text())
    assert pane.proxy.rowCount() == 0


def test_operation_failure_unlocks_actions(window, app):
    def failure():
        raise PermissionError('fixture read-only destination')
    result = QSignalSpy(window.operation_finished)
    window.run_operation(failure)
    wait(app, lambda: result.count() == 1)
    assert not window.busy
    assert window.actions['copy'].isEnabled()
    assert 'fixture read-only' in window.status.text()


def test_browse_zip_and_copy_selected_member(window, app):
    import zipfile
    left, right = window.panes
    archive = left.directory / 'fixture.zip'
    with zipfile.ZipFile(archive, 'w') as stream:
        stream.writestr('folder/note.txt', 'inside archive')
    left.refresh()
    wait(app, lambda: left.proxy.rowCount() == 2)
    entry = next(e for e in left.model.entries if e.name == 'fixture.zip')
    left.open_entry(entry)
    wait(app, lambda: len(left.model.entries) == 1 and left.model.entries[0].name == 'folder')
    left.open_entry(left.model.entries[0])
    wait(app, lambda: len(left.model.entries) == 1 and left.model.entries[0].name == 'note.txt')
    left.table.selectRow(0)
    window.activate(left)
    window.actions['copy'].trigger()
    wait(app, lambda: not window.busy)
    assert (right.directory / 'folder' / 'note.txt').read_text() == 'inside archive'


def test_text_preview(window, app):
    from PySide6.QtWidgets import QTextEdit
    left = window.panes[0]
    window.activate(left)
    left.table.selectRow(0)
    window.actions['preview'].trigger()
    wait(app, lambda: hasattr(window, 'preview_dialog'))
    area = window.preview_dialog.findChild(QTextEdit)
    assert area.toPlainText() == 'Hello from OpenCommander'
    window.preview_dialog.close()


def test_connections_open_mount_and_busy_eject(window, app, monkeypatch, tmp_path):
    from opencommander import integrations
    from opencommander.connections_ui import ConnectionsDialog
    mount = tmp_path / 'Google Drive'
    mount.mkdir()
    records = [dict(id='cloud://test', name='Google Drive', kind='Cloud', path=str(mount),
                    mounted=True, eject=False, unmount=True),
               dict(id='usb-test', name='USB', kind='USB', path=None,
                    mounted=False, eject=False, unmount=False)]
    calls = []
    def invoke(action='list', identifier=''):
        calls.append((action, identifier))
        return records
    monkeypatch.setattr(integrations, 'invoke', invoke)
    dialog = ConnectionsDialog(window)
    wait(app, lambda: not dialog.pending)
    assert dialog.items.count() == 2
    dialog.items.setCurrentRow(0)
    dialog.open_selected()
    assert window.active.directory == mount
    window.busy = True
    dialog.disconnect()
    assert not any(action == 'unmount' for action, _ in calls)
    window.busy = False
    dialog.items.setCurrentRow(1)
    dialog.open_selected()
    wait(app, lambda: not dialog.pending)
    assert ('mount', 'usb-test') in calls
    dialog.address.setText('smb://nas/share')
    dialog.connect_network()
    wait(app, lambda: not dialog.pending)
    assert ('connect', 'smb://nas/share') in calls
    dialog.close()


def test_connections_disconnect_failure_clears_busy(window, app, monkeypatch, tmp_path):
    from opencommander import integrations
    from opencommander.connections_ui import ConnectionsDialog
    from PySide6.QtWidgets import QMessageBox
    mount = tmp_path / 'USB'
    mount.mkdir()
    record = dict(id='file:///test', name='USB', kind='USB', path=str(mount),
                  mounted=True, eject=True, unmount=True)
    def invoke(action='list', identifier=''):
        if action == 'eject':
            raise RuntimeError('Device busy')
        return [record]
    monkeypatch.setattr(integrations, 'invoke', invoke)
    monkeypatch.setattr(QMessageBox, 'question', lambda *args: QMessageBox.Yes)
    dialog = ConnectionsDialog(window)
    wait(app, lambda: not dialog.pending)
    dialog.items.setCurrentRow(0)
    window.active.navigate(mount)
    dialog.disconnect()
    wait(app, lambda: not dialog.pending)
    assert not window.busy
    assert 'Device busy' in dialog.status.text()
    assert window.active.directory == Path.home()
    dialog.close()


@pytest.mark.parametrize('suffix', ['png', 'jpg'])
def test_open_image_uses_internal_viewer(window, app, tmp_path, monkeypatch, suffix):
    from PySide6.QtGui import QImage, QColor, QDesktopServices
    from PySide6.QtWidgets import QLabel
    from opencommander.filesystem import Entry
    image = QImage(80, 60, QImage.Format_RGB32)
    image.fill(QColor('coral'))
    path = tmp_path / ('Bild.' + suffix)
    assert image.save(str(path))
    external = []
    monkeypatch.setattr(QDesktopServices, 'openUrl', lambda url: external.append(url))
    window.active.open_entry(Entry(path.name, path, False))
    wait(app, lambda: hasattr(window, 'preview_dialog'))
    wait(app, lambda: not window.preview_dialog.current_image.isNull())
    labels = window.preview_dialog.findChildren(QLabel)
    assert any(not label.pixmap().isNull() for label in labels)
    assert not external
    assert window.preview_dialog.play.isHidden()
    assert window.preview_dialog.seek.isHidden()
    window.preview_dialog.close()


def test_broken_image_shows_error(window, app, tmp_path):
    from PySide6.QtWidgets import QLabel
    from opencommander.filesystem import Entry
    path = tmp_path / 'broken.png'
    path.write_bytes(b'not a PNG image')
    window.open_entry(Entry(path.name, path, False))
    wait(app, lambda: hasattr(window, 'preview_dialog'))
    wait(app, lambda: window.preview_dialog.message.text() not in ('', 'Loading …', 'Laden …'))
    assert window.preview_dialog.current_image.isNull()
    assert not window.busy
    window.preview_dialog.close()


@pytest.mark.parametrize('accept', [False, True])
def test_default_manager_prompt_once(window, monkeypatch, tmp_path, accept):
    from opencommander import desktop
    from PySide6.QtWidgets import QMessageBox
    from types import SimpleNamespace
    applications = tmp_path / 'applications'
    applications.mkdir()
    (applications / 'opencommander.desktop').write_text('[Desktop Entry]\n')
    monkeypatch.setenv('XDG_DATA_HOME', str(tmp_path))
    questions, calls = [], []
    def question(*args):
        questions.append(args)
        return QMessageBox.Yes if accept else QMessageBox.No
    def run(command, **kwargs):
        calls.append(command)
        return SimpleNamespace(stdout='opencommander.desktop\n')
    monkeypatch.setattr(QMessageBox, 'question', question)
    monkeypatch.setattr(desktop.subprocess, 'run', run)
    desktop.ask_default(window)
    desktop.ask_default(window)
    assert len(questions) == 1
    assert len(calls) == (2 if accept else 0)
    if accept:
        assert calls[0] == ['xdg-mime', 'default', 'opencommander.desktop', 'inode/directory']
        assert calls[1][:2] == ['/usr/bin/python3', '-c']
        assert 'Gio.AppInfo.get_default_for_type' in calls[1][2]


def test_default_manager_failure_can_retry(window, monkeypatch):
    from opencommander import desktop
    from PySide6.QtWidgets import QMessageBox
    import subprocess
    monkeypatch.setattr(QMessageBox, 'question', lambda *args: QMessageBox.Yes)
    warnings = []
    monkeypatch.setattr(QMessageBox, 'warning', lambda *args: warnings.append(args))
    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(1, 'xdg-mime')
    monkeypatch.setattr(desktop.subprocess, 'run', fail)
    desktop.ask_default(window)
    assert warnings
    assert not window.settings.value('default_manager_prompted', False, type=bool)


def test_media_navigation_thumbnails_and_toggle(window, app):
    from PySide6.QtGui import QImage, QColor
    from PySide6.QtWidgets import QComboBox
    pane = window.panes[0]
    for name, color in [('01.png', 'red'), ('02.png', 'blue')]:
        image = QImage(120, 60, QImage.Format_RGB32)
        image.fill(QColor(color))
        assert image.save(str(pane.directory / name))
    pane.refresh()
    wait(app, lambda: pane.proxy.rowCount() == 3)
    entry = next(e for e in pane.model.entries if e.name == '01.png')
    row = pane.model.entries.index(entry)
    pane.model.data(pane.model.index(row, 0), Qt.DecorationRole)
    key = (str(entry.path), entry.size, entry.modified)
    wait(app, lambda: key in window.thumbnails.cache)
    assert window.thumbnails.cache[key] is not None
    assert not isinstance(window.mode, QComboBox)
    QTest.mouseClick(window.mode.switch, Qt.LeftButton)
    assert window.mode.currentData() == 'move'
    window.activate(pane)
    window.open_entry(entry)
    viewer = window.preview_dialog
    wait(app, lambda: not viewer.current_image.isNull())
    assert viewer.current_image.pixelColor(0, 0).red() == 255
    viewer.activateWindow()
    viewer.setFocus()
    QTest.keyClick(viewer, Qt.Key_Right)
    wait(app, lambda: viewer.index == 1 and not viewer.current_image.isNull())
    assert viewer.current_image.pixelColor(0, 0).blue() == 255
    QTest.keyClick(viewer, Qt.Key_Left)
    wait(app, lambda: viewer.index == 0 and not viewer.current_image.isNull())
    viewer.close()


def test_audio_opens_in_media_viewer_and_stops_on_close(window, app):
    import wave
    from opencommander.filesystem import Entry
    from PySide6.QtMultimedia import QMediaPlayer
    path = window.panes[0].directory / 'tone.wav'
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(8000)
        output.writeframes(b'\x00\x00' * 8000)
    window.open_entry(Entry(path.name, path, False))
    viewer = window.preview_dialog
    wait(app, lambda: viewer.player.source().toLocalFile() == str(path))
    assert viewer.play.isEnabled()
    wait(app, lambda: viewer.player.duration() > 0)
    viewer.shutdown()
    assert viewer.player.playbackState() == QMediaPlayer.StoppedState
    assert viewer.player.source().isEmpty()
    viewer.close()


def test_video_plays_in_viewer(window, app, tmp_path):
    import shutil
    import subprocess
    from opencommander.filesystem import Entry
    if not shutil.which('ffmpeg'):
        pytest.skip('ffmpeg fixture generator not installed')
    path = tmp_path / 'movie.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=160x90:d=1',
                    '-c:v', 'mpeg4', str(path)], check=True, timeout=10)
    window.open_entry(Entry(path.name, path, False))
    viewer = window.preview_dialog
    wait(app, lambda: viewer.video.videoSink().videoFrame().isValid())
    assert viewer.stack.currentWidget() == viewer.video
    assert not viewer.play.isHidden()
    assert not viewer.seek.isHidden()
    assert viewer.player.duration() > 0
    viewer.close()


@pytest.mark.parametrize('move', [False, True])
@pytest.mark.parametrize('folder_target', [False, True])
def test_mouse_gesture_starts_drag_and_transfers(window, app, monkeypatch, move, folder_target):
    from PySide6.QtCore import QEvent, QPoint
    from PySide6.QtGui import QMouseEvent
    from opencommander import ui
    left, right = window.panes
    window.mode.setCurrentIndex(int(move))
    destination = right.directory
    drop_position = QPointF(20, 250)
    if folder_target:
        destination = right.directory / 'Destination'
        destination.mkdir()
        right.refresh()
        wait(app, lambda: right.proxy.rowCount() == 1)
        target_index = right.proxy.index(0, 0)
        assert target_index.flags() & Qt.ItemIsDropEnabled
        drop_position = QPointF(right.table.visualRect(target_index).center())
    gestures = []
    class Drag:
        def __init__(self, source):
            self.source = source
        def setMimeData(self, mime):
            self.mime = mime
        def exec(self, actions):
            gestures.append(self.mime.urls())
            event = QDropEvent(drop_position, actions, self.mime, Qt.LeftButton, Qt.NoModifier)
            right.table.dropEvent(event)
            assert event.isAccepted()
            return Qt.CopyAction
    monkeypatch.setattr(ui, 'QDrag', Drag)
    index = left.proxy.index(0, 0)
    assert index.flags() & Qt.ItemIsDragEnabled
    viewport = left.table.viewport()
    start = left.table.visualRect(index).center()
    QTest.mousePress(viewport, Qt.LeftButton, Qt.NoModifier, start)
    for distance in (2, QApplication.startDragDistance() + 20, QApplication.startDragDistance() + 40):
        point = start + QPoint(distance, 0)
        event = QMouseEvent(QEvent.MouseMove, QPointF(point), QPointF(viewport.mapToGlobal(point)),
                            Qt.NoButton, Qt.LeftButton, Qt.NoModifier)
        QApplication.sendEvent(viewport, event)
    QTest.mouseRelease(viewport, Qt.LeftButton, Qt.NoModifier, start)
    wait(app, lambda: not window.busy)
    assert len(gestures) == 1
    assert (destination / 'Grüße.txt').read_text() == 'Hello from OpenCommander'
    assert (left.directory / 'Grüße.txt').exists() == (not move)


def test_history_details_thumbnail_and_individual_undo(window, app):
    from PySide6.QtGui import QImage, QColor
    left, right = window.panes
    image_path = left.directory / 'Photo.png'
    image = QImage(96, 64, QImage.Format_RGB32)
    image.fill(QColor('gold'))
    image.save(str(image_path))
    window.engine.transfer([image_path], right.directory)
    window.engine.transfer([left.directory / 'Grüße.txt'], right.directory)
    window.reload_history()
    window.history_dock.show()
    app.processEvents()
    assert window.history_list.count() == 2
    image_item = window.history_list.item(1)
    card = window.history_list.itemWidget(image_item)
    assert str(image_path) in card.details.toPlainText()
    assert str(right.directory / 'Photo.png') in card.details.toPlainText()
    window.history_list.scrollToItem(image_item)
    window.load_history_previews()
    wait(app, lambda: not card.thumbnail_label.pixmap().isNull())
    QTest.mouseClick(card.undo_button, Qt.LeftButton)
    wait(app, lambda: not window.busy)
    assert not (right.directory / 'Photo.png').exists()
    assert image_path.exists()
    assert (right.directory / 'Grüße.txt').exists()
    assert window.history_list.count() == 1


def test_context_properties_uses_clicked_file_and_fresh_metadata(window, app, monkeypatch):
    from PySide6.QtWidgets import QMenu
    from opencommander import properties_ui
    pane = window.panes[0]
    (pane.directory / 'Zweite.txt').write_text('different')
    pane.refresh()
    wait(app, lambda: pane.proxy.rowCount() == 2)
    pane.table.selectRow(0)
    from PySide6.QtCore import QTimer
    QTimer.singleShot(30, lambda: app.activePopupWidget().close() if app.activePopupWidget() else None)
    index = pane.proxy.index(1, 0)
    clicked = pane.entry_at(index)
    pane.table.context_menu(pane.table.visualRect(index).center())
    assert pane.selected() == [clicked]
    monkeypatch.setattr(properties_ui, 'invoke', lambda *args:
                        dict(name=clicked.name, path=str(clicked.path), size=12345, directory=False))
    window.info()
    wait(app, lambda: '12,345 Bytes' in window.properties_dialog.details.toPlainText())
    assert clicked.name in window.properties_dialog.details.toPlainText()
    window.properties_dialog.close()


def test_toolbar_extract_only_for_archive_and_no_folder_button(window, app):
    import zipfile
    pane = window.panes[0]
    window.activate(pane)
    pane.table.selectRow(0)
    assert not window.actions['extract'].isVisible()
    assert window.actions['folder'] not in window.toolbar.actions()
    path = pane.directory / 'test.zip'
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('a.txt', 'text')
    pane.refresh()
    wait(app, lambda: pane.proxy.rowCount() == 2)
    row = next(row for row in range(2) if pane.entry_at(pane.proxy.index(row, 0)).name == 'test.zip')
    pane.table.selectRow(row)
    assert window.actions['extract'].isVisible()
    window.activate(window.panes[1])
    assert not window.actions['extract'].isVisible()
    window.activate(pane)
    pane.open_entry(pane.selected()[0])
    wait(app, lambda: pane.archive == path and pane.proxy.rowCount() == 1)
    assert window.actions['extract'].isVisible()


def test_open_with_selected_application_and_cancel(window, app, monkeypatch):
    from opencommander import integrations
    pane = window.panes[0]
    window.activate(pane)
    pane.table.selectRow(0)
    calls = []
    def invoke(action, identifier):
        calls.append((action, identifier))
        return {'launched': False}
    monkeypatch.setattr(integrations, 'invoke', invoke)
    window.actions['open_with'].trigger()
    wait(app, lambda: not window.busy)
    assert calls == [('open-with', str(pane.directory / 'Grüße.txt'))]
    assert not window.engine.history
    assert window.status.text() in ('Abgebrochen', 'Cancelled')
    assert (pane.directory / 'Grüße.txt').exists()
