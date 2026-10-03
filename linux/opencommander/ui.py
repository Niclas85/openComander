from __future__ import annotations

from datetime import datetime
from pathlib import Path, PurePosixPath
import json
import os
import shutil
import tempfile
import time
import zipfile

from PySide6.QtCore import (Qt, Signal, QObject, QRunnable, QThreadPool, QAbstractTableModel,
    QModelIndex, QSortFilterProxyModel, QUrl, QMimeData, QTimer, QDir, QFileSystemWatcher,
    QSettings, QStandardPaths, QSize, QItemSelectionModel)
from PySide6.QtGui import (QAction, QKeySequence, QDrag, QDesktopServices, QImageReader,
    QPixmap, QIcon, QColor)
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QLineEdit, QSplitter, QTreeView, QTableView, QFileSystemModel,
    QAbstractItemView, QHeaderView, QComboBox, QProgressBar, QToolBar, QMenu, QFileDialog,
    QInputDialog, QMessageBox, QDialog, QTextEdit, QScrollArea, QDockWidget, QListWidget,
    QListWidgetItem, QStyle, QFrame, QCheckBox)

from .filesystem import listing, archive_listing, mounted_locations, cloud_locations, remote_location, Entry
from .operations import FileEngine, SafetyError, exists, unique_path, checked_members
from .i18n import text
from . import __version__
from .media import media_kind, ThumbnailCache, MediaViewer
from .controls import ModeToggle
from .location_preferences import load_preferences, configured_locations
from shiboken6 import isValid


def human_size(value):
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if value < 1024 or unit == 'TiB':
            return f'{value:.0f} {unit}' if unit == 'B' else f'{value:.1f} {unit}'
        value /= 1024


class TaskSignals(QObject):
    result = Signal(object, object)
    progress = Signal(int, str)


class Task(QRunnable):
    def __init__(self, work):
        super().__init__()
        self.work = work
        self.signals = TaskSignals()

    def run(self):
        try:
            value = self.work()
        except Exception as error:
            self.signals.result.emit(None, error)
        else:
            self.signals.result.emit(value, None)


class EntryModel(QAbstractTableModel):
    def __init__(self, pane):
        super().__init__(pane)
        self.pane = pane
        self.entries = []
        style = QApplication.style()
        self.folder_icon = QIcon(style.standardIcon(QStyle.SP_DirIcon).pixmap(24, 24))
        self.file_icon = QIcon(style.standardIcon(QStyle.SP_FileIcon).pixmap(24, 24))
        self.link_icon = QIcon(style.standardIcon(QStyle.SP_FileLinkIcon).pixmap(24, 24))

    def rowCount(self, parent=QModelIndex()):
        return 0 if parent.isValid() else len(self.entries)

    def flags(self, index):
        flags = super().flags(index)
        if self.pane.archive:
            return flags
        if not index.isValid():
            return flags | Qt.ItemIsDropEnabled
        entry = self.entries[index.row()]
        if not entry.error:
            flags |= Qt.ItemIsDragEnabled
        if entry.directory:
            flags |= Qt.ItemIsDropEnabled
        return flags

    def supportedDragActions(self):
        return Qt.CopyAction

    def columnCount(self, parent=QModelIndex()):
        return 4

    def headerData(self, section, orientation, role=Qt.DisplayRole):
        if orientation == Qt.Horizontal and role == Qt.DisplayRole:
            return self.pane.main.tr_key(('name', 'size', 'type', 'modified')[section])

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid():
            return None
        item = self.entries[index.row()]
        column = index.column()
        if role == Qt.UserRole:
            return (item.name.casefold(), item.size,
                    '0' if item.directory else item.path.suffix, item.modified)[column]
        if role == Qt.ForegroundRole and column == 0:
            dark = self.pane.main.dark
            if item.error:
                return QColor('#ff919c' if dark else '#b42338')
            if item.directory:
                return QColor('#88baff' if dark else '#185bb5')
            suffix = item.path.suffix.lower()
            if suffix in ('.zip', '.tar', '.gz', '.7z', '.rar'):
                return QColor('#f1c36d' if dark else '#885400')
            if suffix in ('.png', '.jpg', '.jpeg', '.svg', '.mp4', '.mp3', '.webp'):
                return QColor('#cfadff' if dark else '#753bb0')
        if role == Qt.DecorationRole and column == 0:
            thumbnail = self.pane.main.thumbnails.get(item, self, index.row())
            if thumbnail is not None:
                return thumbnail
            return self.link_icon if item.link else self.folder_icon if item.directory else self.file_icon
        if role == Qt.TextAlignmentRole and column == 1:
            return int(Qt.AlignRight | Qt.AlignVCenter)
        if role == Qt.ToolTipRole:
            return str(item.path) + (f'!/{item.member}' if item.member else '') + ('\n' + item.error if item.error else '')
        if role != Qt.DisplayRole:
            return None
        kind = self.pane.main.tr_key('link' if item.link else 'directory' if item.directory else 'file')
        if item.error:
            return (item.name, '—', '⚠', '—')[column]
        return (item.name, '—' if item.directory else human_size(item.size),
                kind if item.directory or item.link else Path(item.name).suffix.removeprefix('.').upper() or kind,
                datetime.fromtimestamp(item.modified).strftime('%d.%m.%Y %H:%M') if item.modified else '—')[column]

    def replace(self, entries):
        self.beginResetModel()
        self.entries = entries
        self.endResetModel()


class EntryProxy(QSortFilterProxyModel):
    def lessThan(self, left, right):
        a, b = self.sourceModel().entries[left.row()], self.sourceModel().entries[right.row()]
        if a.directory != b.directory:
            return a.directory if self.sortOrder() == Qt.AscendingOrder else b.directory
        return super().lessThan(left, right)


class FileTable(QTableView):
    def __init__(self, pane):
        super().__init__(pane)
        self.pane = pane
        self.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.setDragEnabled(True)
        self.setAcceptDrops(True)
        self.setDropIndicatorShown(True)
        self.setDragDropMode(QAbstractItemView.DragDrop)
        self.setAlternatingRowColors(True)
        self.setShowGrid(False)
        self.setSortingEnabled(True)
        self.setHorizontalScrollMode(QAbstractItemView.ScrollPerPixel)
        self.verticalHeader().hide()
        self.verticalHeader().setDefaultSectionSize(52)
        self.setIconSize(QSize(72, 44))
        self.setContextMenuPolicy(Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(self.context_menu)

    def focusInEvent(self, event):
        self.pane.main.activate(self.pane)
        super().focusInEvent(event)

    def startDrag(self, supported):
        entries = self.pane.selected()
        if self.pane.archive or self.pane.main.busy or not entries:
            return
        mime = QMimeData()
        mime.setUrls([QUrl.fromLocalFile(str(e.path)) for e in entries])
        drag = QDrag(self)
        drag.setMimeData(mime)
        drag.exec(Qt.CopyAction)  # The receiver owns transfers; never request a second deletion.

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls() and not self.pane.archive and not self.pane.main.busy:
            event.acceptProposedAction()
        else:
            event.ignore()

    def dragMoveEvent(self, event):
        self.dragEnterEvent(event)

    def dropEvent(self, event):
        if self.pane.archive or self.pane.main.busy:
            event.ignore()
            return
        entry = self.pane.entry_at(self.indexAt(event.position().toPoint()))
        directory = entry.path if entry and entry.directory else self.pane.directory
        self.pane.main.drop_urls(event.mimeData().urls(), directory)
        event.setDropAction(Qt.CopyAction)
        event.accept()

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key_Return, Qt.Key_Enter):
            self.pane.main.open_selected()
        elif event.key() == Qt.Key_Space and not event.modifiers():
            self.pane.main.preview_selected()
        else:
            super().keyPressEvent(event)

    def context_menu(self, point):
        index = self.indexAt(point)
        if not index.isValid():
            return
        if not self.selectionModel().isRowSelected(index.row()):
            self.clearSelection()
            self.selectRow(index.row())
        self.selectionModel().setCurrentIndex(index, QItemSelectionModel.NoUpdate)
        self.pane.main.activate(self.pane)
        menu = QMenu(self)
        for key in ('open', 'open_with', 'preview', 'copy', 'move', 'rename', 'zip', 'extract', 'trash', 'info'):
            menu.addAction(self.pane.main.actions[key])
        menu.exec(self.viewport().mapToGlobal(point))


class FolderTree(QTreeView):
    def __init__(self, pane):
        super().__init__(pane)
        self.pane = pane
        self.setHeaderHidden(True)
        self.setAcceptDrops(True)
        self.setDragDropMode(QAbstractItemView.DropOnly)

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls() and not self.pane.main.busy:
            event.acceptProposedAction()
        else:
            event.ignore()

    def dragMoveEvent(self, event):
        self.dragEnterEvent(event)

    def dropEvent(self, event):
        index = self.indexAt(event.position().toPoint())
        if not index.isValid() or self.pane.main.busy:
            event.ignore()
            return
        self.pane.main.drop_urls(event.mimeData().urls(), Path(self.pane.tree_model.filePath(index)))
        event.setDropAction(Qt.CopyAction)
        event.accept()


class Pane(QFrame):
    def __init__(self, main, number, directory):
        super().__init__()
        self.main, self.number = main, number
        self.directory, self.archive, self.prefix = Path(directory), None, ''
        self.navigation, self.nav_index = [], -1
        self.generation = 0
        self.setObjectName('pane')
        self.setProperty('side', str(number))
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 8)
        layout.setSpacing(8)
        title_row = QHBoxLayout()
        self.title = QLabel()
        self.title.setObjectName('paneTitle')
        title_row.addWidget(self.title)
        title_row.addStretch()
        self.selected_label = QLabel()
        self.selected_label.setObjectName('muted')
        title_row.addWidget(self.selected_label)
        layout.addLayout(title_row)
        navigation = QHBoxLayout()
        for label, hint, callback in [('‹', 'Alt+Left', lambda: self.travel(-1)),
                                      ('›', 'Alt+Right', lambda: self.travel(1)),
                                      ('↑', 'Alt+Up', self.up)]:
            button = QPushButton(label)
            button.setFixedWidth(32)
            button.setToolTip(hint)
            button.clicked.connect(callback)
            navigation.addWidget(button)
        self.path_edit = QLineEdit()
        self.path_edit.setAccessibleName(f'Path {number}')
        self.path_edit.returnPressed.connect(self.navigate_text)
        navigation.addWidget(self.path_edit, 1)
        layout.addLayout(navigation)
        splitter = QSplitter(Qt.Horizontal)
        self.tree_model = QFileSystemModel(self)
        self.tree_model.setFilter(QDir.AllDirs | QDir.NoDotAndDotDot | (QDir.Hidden if main.hidden else QDir.Filter(0)))
        self.tree_model.setRootPath('/')
        self.tree = FolderTree(self)
        self.tree.setModel(self.tree_model)
        self.tree.setRootIndex(self.tree_model.index('/'))
        for column in range(1, 4):
            self.tree.hideColumn(column)
        self.tree.clicked.connect(lambda index: self.navigate(Path(self.tree_model.filePath(index))))
        self.tree_model.directoryLoaded.connect(lambda _: self.sync_tree())
        self.tree.setMinimumWidth(110)
        splitter.addWidget(self.tree)
        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(0, 0, 0, 0)
        self.filter = QLineEdit()
        self.filter.setClearButtonEnabled(True)
        right_layout.addWidget(self.filter)
        self.model = EntryModel(self)
        self.proxy = EntryProxy(self)
        self.proxy.setSourceModel(self.model)
        self.proxy.setSortRole(Qt.UserRole)
        self.proxy.setFilterCaseSensitivity(Qt.CaseInsensitive)
        self.proxy.setFilterKeyColumn(0)
        self.filter.textChanged.connect(self.proxy.setFilterFixedString)
        self.filter.textChanged.connect(lambda _: self.selection_changed())
        self.table = FileTable(self)
        self.table.setModel(self.proxy)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for column, width in ((1, 90), (2, 70), (3, 125)):
            self.table.setColumnWidth(column, width)
        self.table.sortByColumn(0, Qt.AscendingOrder)
        self.table.doubleClicked.connect(lambda index: self.open_entry(self.entry_at(index)))
        self.table.selectionModel().selectionChanged.connect(self.selection_changed)
        right_layout.addWidget(self.table)
        self.message = QLabel()
        self.message.setWordWrap(True)
        self.message.setObjectName('muted')
        right_layout.addWidget(self.message)
        splitter.addWidget(right)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([155, 475])
        layout.addWidget(splitter, 1)
        self.watcher = QFileSystemWatcher(self)
        self.refresh_timer = QTimer(self)
        self.refresh_timer.setSingleShot(True)
        self.refresh_timer.setInterval(250)
        self.refresh_timer.timeout.connect(lambda: self.refresh() if not self.main.busy else None)
        self.watcher.directoryChanged.connect(lambda _: self.refresh_timer.start())
        self.navigate(self.directory)

    def location(self):
        return (self.directory, self.archive, self.prefix)

    def navigate(self, directory, archive=None, prefix='', remember=True):
        self.main.activate(self)
        directory = Path(os.path.abspath(directory))
        self.directory, self.archive, self.prefix = directory, archive, prefix
        if remember:
            del self.navigation[self.nav_index + 1:]
            if not self.navigation or self.navigation[-1] != self.location():
                self.navigation.append(self.location())
            self.nav_index = len(self.navigation) - 1
        self.path_edit.setText(str(archive) + '!/' + prefix if archive else str(directory))
        self.filter.clear()
        if self.watcher.directories():
            self.watcher.removePaths(self.watcher.directories())
        if not remote_location(directory) and directory.is_dir():
            self.watcher.addPath(str(directory))
        self.main.settings.setValue(f'pane{self.number}', str(directory))
        self.sync_tree()
        self.refresh()

    def sync_tree(self):
        if remote_location(self.directory):
            return
        index = self.tree_model.index(str(self.directory))
        if index.isValid():
            parent = index.parent()
            while parent.isValid():
                self.tree.expand(parent)
                parent = parent.parent()
            self.tree.setCurrentIndex(index)
            self.tree.scrollTo(index)

    def navigate_text(self):
        value = os.path.expanduser(self.path_edit.text())
        marker = value.lower().find('.zip!/')
        if marker >= 0:
            archive = Path(value[:marker + 4])
            prefix = value[marker + 6:]
            self.navigate(archive.parent, archive, prefix.rstrip('/') + '/' if prefix else '')
        else:
            self.navigate(Path(value))

    def travel(self, delta):
        index = self.nav_index + delta
        if 0 <= index < len(self.navigation):
            self.nav_index = index
            self.navigate(*self.navigation[index], remember=False)

    def up(self):
        if self.archive and self.prefix:
            prefix = str(PurePosixPath(self.prefix.rstrip('/')).parent)
            self.navigate(self.directory, self.archive, '' if prefix == '.' else prefix + '/')
        elif self.archive:
            self.navigate(self.archive.parent)
        else:
            self.navigate(self.directory.parent)

    def refresh(self):
        self.generation += 1
        generation = self.generation
        directory, archive, prefix = self.location()
        self.message.setText(self.main.tr_key('loading'))
        hidden = self.main.hidden
        task = Task(lambda: archive_listing(archive, prefix) if archive else listing(directory, hidden))
        def done(entries, error):
            if generation != self.generation:
                return
            self.model.replace(entries or [])
            self.message.setText(str(error) if error else self.main.tr_key('empty') if not entries else '')
            self.selection_changed()
        task.signals.result.connect(done)
        self.main.start_background(task)

    def entry_at(self, index):
        if not index.isValid():
            return None
        return self.model.entries[self.proxy.mapToSource(index).row()]

    def selected(self):
        return [self.entry_at(index) for index in self.table.selectionModel().selectedRows()]

    def selection_changed(self, *args):
        selected = self.selected()
        self.selected_label.setText(f'{len(selected)} {self.main.tr_key("selected")}  ·  '
            f'{self.proxy.rowCount()} {self.main.tr_key("items")}')
        if self.main.active is self:
            self.main.update_context_actions()

    def open_entry(self, entry):
        if not entry:
            return
        self.main.activate(self)
        if entry.error:
            self.message.setText(entry.error)
            return
        if entry.member:
            if entry.directory:
                self.navigate(self.directory, self.archive, entry.member)
            else:
                self.main.open_entry(entry)
        elif entry.directory:
            self.navigate(entry.path)
        elif entry.path.suffix.lower() == '.zip':
            self.navigate(entry.path.parent, entry.path)
        else:
            self.main.open_entry(entry)

    def retranslate(self):
        self.filter.setPlaceholderText(self.main.tr_key('filter'))
        self.model.headerDataChanged.emit(Qt.Horizontal, 0, 3)
        self.selection_changed()


class MainWindow(QMainWindow):
    operation_finished = Signal(object)

    def __init__(self, state_dir, left=None, right=None):
        super().__init__()
        self.state_dir = Path(state_dir)
        self.engine = FileEngine(self.state_dir)
        self.settings = QSettings(str(self.state_dir / 'settings.ini'), QSettings.IniFormat)
        self.location_preferences = load_preferences(self.settings.value('locations', '[]'))
        locale = os.environ.get('LANG', 'en')
        self.language = str(self.settings.value('language', 'de' if locale.startswith('de') else 'en'))
        self.dark = self.settings.value('dark', True, type=bool)
        self.hidden = self.settings.value('hidden', False, type=bool)
        self.busy = False
        self.active = None
        self.panes = []
        self.tasks = set()
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(4)
        self.thumbnails = ThumbnailCache(self)
        self.setWindowTitle(f'OpenCommander · Linux {__version__}')
        self.resize(1440, 880)
        self.setMinimumSize(1000, 580)
        icon = Path(__file__).resolve().parent / 'assets' / 'opencommander.png'
        self.setWindowIcon(QIcon(str(icon)))
        central = QWidget()
        layout = QVBoxLayout(central)
        layout.setContentsMargins(16, 12, 16, 10)
        layout.setSpacing(10)
        self.setCentralWidget(central)
        header = QHBoxLayout()
        brand = QLabel('OpenCommander')
        brand.setObjectName('brand')
        header.addWidget(brand)
        label = QLabel('LINUX ' + __version__)
        label.setObjectName('badge')
        header.addWidget(label)
        header.addStretch()
        self.mode_label = QLabel()
        header.addWidget(self.mode_label)
        self.mode = ModeToggle()
        header.addWidget(self.mode)
        self.language_combo = QComboBox()
        self.language_combo.addItem('Deutsch', 'de')
        self.language_combo.addItem('English', 'en')
        self.language_combo.setCurrentIndex(0 if self.language == 'de' else 1)
        self.language_combo.currentIndexChanged.connect(self.change_language)
        header.addWidget(self.language_combo)
        self.theme_button = QCheckBox()
        self.theme_button.setChecked(self.dark)
        self.theme_button.clicked.connect(self.toggle_theme)
        header.addWidget(self.theme_button)
        self.location_settings_button = QPushButton('Einstellungen / Orte' if self.language == 'de' else 'Settings / Locations')
        self.location_settings_button.clicked.connect(self.location_settings)
        header.addWidget(self.location_settings_button)
        location_settings_action = QAction(self)
        location_settings_action.setShortcut(QKeySequence('Ctrl+,'))
        location_settings_action.triggered.connect(self.location_settings)
        self.addAction(location_settings_action)
        layout.addLayout(header)
        self.actions = {}
        callbacks = {
            'copy': (lambda: self.transfer(False), 'F5'), 'move': (lambda: self.transfer(True), 'F6'),
            'rename': (self.rename_selected, 'F2'), 'trash': (self.trash_selected, 'Delete'),
            'zip': (self.zip_selected, ''), 'extract': (self.extract_selected, ''),
            'undo': (self.undo, 'Ctrl+Z'), 'new_folder': (self.new_folder, 'Ctrl+Shift+N'),
            'open_with': (self.open_with_selected, ''),
            'open': (self.open_selected, 'Ctrl+O'), 'preview': (self.preview_selected, 'Ctrl+Y'),
            'refresh': (self.refresh_all, 'Ctrl+R'), 'hidden': (self.toggle_hidden, 'Ctrl+H'),
            'folder': (self.choose_folder, 'Ctrl+Shift+O'), 'history': (self.toggle_history, ''),
            'help': (self.help, 'F1'), 'info': (self.info, 'Ctrl+I'),
        }
        self.toolbar = QToolBar()
        self.toolbar.setToolButtonStyle(Qt.ToolButtonTextOnly)
        for key, (callback, shortcut) in callbacks.items():
            action = QAction(self)
            if shortcut:
                action.setShortcut(QKeySequence(shortcut))
            action.triggered.connect(callback)
            self.actions[key] = action
            self.addAction(action)
        self.actions['hidden'].setCheckable(True)
        self.actions['hidden'].setChecked(self.hidden)
        for key in ('rename', 'new_folder', 'trash', 'zip', 'extract', 'preview', 'undo', 'history', 'help'):
            self.toolbar.addAction(self.actions[key])
            self.toolbar.widgetForAction(self.actions[key]).setProperty('actionKind', key)
        self.hidden_checkbox = QCheckBox()
        self.hidden_checkbox.setChecked(self.hidden)
        self.hidden_checkbox.clicked.connect(self.toggle_hidden)
        self.toolbar.addWidget(self.hidden_checkbox)
        layout.addWidget(self.toolbar)
        self.places = QHBoxLayout()
        places_widget = QWidget()
        places_widget.setObjectName('places')
        places_widget.setLayout(self.places)
        places_scroll = QScrollArea()
        places_scroll.setWidgetResizable(True)
        places_scroll.setWidget(places_widget)
        places_scroll.setFixedHeight(68)
        layout.addWidget(places_scroll)
        self.integration_locations = []
        self.integration_scanning = False
        self.integration_timer = QTimer(self)
        self.integration_timer.timeout.connect(self.scan_integrations)
        self.integration_timer.start(5000)
        QTimer.singleShot(0, self.scan_integrations)
        split = QSplitter(Qt.Horizontal)
        downloads = Path(QStandardPaths.writableLocation(QStandardPaths.DownloadLocation))
        defaults = [left or self.settings.value('pane1', '/'), right or self.settings.value('pane2', str(downloads if downloads.is_dir() else Path.home()))]
        for index, path in enumerate(defaults, 1):
            pane = Pane(self, index, Path(path))
            self.panes.append(pane)
            split.addWidget(pane)
        split.setSizes([700, 700])
        layout.addWidget(split, 1)
        self.status = QLabel()
        self.status.setObjectName('muted')
        self.status.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.progress = QProgressBar()
        self.progress.setFixedWidth(160)
        self.progress.hide()
        self.cancel_button = QPushButton()
        self.cancel_button.clicked.connect(self.engine.cancel.set)
        self.cancel_button.hide()
        footer = QHBoxLayout()
        footer.addWidget(self.status, 1)
        footer.addWidget(self.progress)
        footer.addWidget(self.cancel_button)
        layout.addLayout(footer)
        self.history_dock = QDockWidget(self)
        self.history_list = QListWidget()
        self.history_list.setSpacing(8)
        self.history_list.setFlow(QListWidget.LeftToRight)
        self.history_list.setWrapping(False)
        self.history_list.horizontalScrollBar().valueChanged.connect(self.load_history_previews)
        self.history_dock.setMinimumWidth(380)
        self.history_dock.setMinimumHeight(345)
        self.history_list.verticalScrollBar().valueChanged.connect(self.load_history_previews)
        self.history_dock.visibilityChanged.connect(lambda visible: self.load_history_previews() if visible else None)
        self.history_dock.setWidget(self.history_list)
        self.addDockWidget(Qt.BottomDockWidgetArea, self.history_dock)
        self.history_dock.hide()
        # Clipboard shortcuts belong to file lists. Text edits retain their normal shortcuts.
        for pane in self.panes:
            for sequence, callback in [('Ctrl+C', lambda: self.copy_clipboard(False)),
                ('Ctrl+X', lambda: self.copy_clipboard(True)), ('Ctrl+V', self.paste_clipboard),
                ('Ctrl+A', pane.table.selectAll)]:
                action = QAction(pane.table)
                action.setShortcut(QKeySequence(sequence))
                action.setShortcutContext(Qt.WidgetShortcut)
                action.triggered.connect(callback)
                pane.table.addAction(action)
        for sequence, callback in [('Ctrl+L', self.focus_path), ('Alt+Up', lambda: self.active.up()),
             ('Alt+Left', lambda: self.active.travel(-1)), ('Alt+Right', lambda: self.active.travel(1))]:
            action = QAction(self)
            action.setShortcut(QKeySequence(sequence))
            action.triggered.connect(callback)
            self.addAction(action)
        self.retranslate()
        self.apply_theme()
        self.activate(self.panes[0])
        self.status.setText(self.tr_key('ready'))
        saved_geometry = self.settings.value('geometry')
        if saved_geometry is not None:
            self.restoreGeometry(saved_geometry)
        self.reload_history()
        self.history_dock.setVisible(self.settings.value('history_visible', False, type=bool))
        if self.engine.load_error:
            self.status.setText(self.engine.load_error)

    def tr_key(self, key):
        return text(self.language, key)

    def activate(self, pane):
        self.active = pane
        for p in self.panes:
            accent = ('#6caaff' if p.number == 1 else '#60c69d') if self.dark else ('#1e66c1' if p.number == 1 else '#1f8a5b')
            active = '  •  ' + self.tr_key('active') if p == pane else ''
            p.title.setText(self.tr_key('left' if p.number == 1 else 'right') + active)
            p.title.setStyleSheet(f'color: {accent}; font-weight: 700; letter-spacing: 1px;')
        self.update_context_actions()

    def update_context_actions(self):
        if not self.active or not hasattr(self.active, 'table'):
            return
        selected = self.active.selected()
        archive = bool(self.active.archive) or (len(selected) == 1 and not selected[0].directory
                   and selected[0].path.suffix.lower() == '.zip')
        self.actions['extract'].setVisible(archive)
        self.actions['extract'].setEnabled(archive and not self.busy)

    def start_background(self, task):
        self.tasks.add(task)
        task.signals.result.connect(lambda *_: self.tasks.discard(task))
        self.pool.start(task)

    def run_operation(self, callback, after=None):
        if self.busy:
            return
        self.busy = True
        for row in range(self.history_list.count()):
            card = self.history_list.itemWidget(self.history_list.item(row))
            if card:
                card.undo_button.setEnabled(False)
        self.engine.cancel.clear()
        self.status.setText(self.tr_key('working'))
        self.progress.setRange(0, 0)
        self.progress.show()
        self.cancel_button.show()
        for key, action in self.actions.items():
            if key not in ('help', 'history', 'hidden', 'refresh'):
                action.setEnabled(False)
        task = Task(callback)
        last_progress = [0.0]
        def progress(count, name):
            now = time.monotonic()
            if now - last_progress[0] >= 0.1:
                last_progress[0] = now
                task.signals.progress.emit(count // 1024, name)
        self.engine.progress = progress
        task.signals.progress.connect(lambda kib, name: self.status.setText(f'{self.tr_key("working")}  {human_size(kib * 1024)}  ·  {name}'))
        def done(value, error):
            self.busy = False
            self.engine.progress = lambda *_: None
            self.progress.hide()
            self.cancel_button.hide()
            for action in self.actions.values():
                action.setEnabled(True)
            self.update_context_actions()
            self.reload_history()
            self.refresh_all()
            self.status.setText(str(error) if error else self.tr_key('done'))
            if not error and after:
                after(value)
            self.operation_finished.emit(error)
        task.signals.result.connect(done)
        self.start_background(task)

    def conflict_mode(self, paths, directory):
        if not any(exists(Path(directory) / Path(p).name) and Path(p) != Path(directory) / Path(p).name for p in paths):
            return 'keep'
        dialog = QMessageBox(self)
        dialog.setWindowTitle(self.tr_key('copy'))
        dialog.setText(self.tr_key('conflict'))
        keep = dialog.addButton(self.tr_key('keep'), QMessageBox.AcceptRole)
        replace = dialog.addButton(self.tr_key('replace'), QMessageBox.DestructiveRole)
        dialog.addButton(self.tr_key('cancel'), QMessageBox.RejectRole)
        dialog.exec()
        return 'keep' if dialog.clickedButton() == keep else 'replace' if dialog.clickedButton() == replace else None

    def transfer(self, move=False, paths=None, directory=None):
        if self.busy:
            return
        pane = self.active
        target_pane = self.panes[1] if pane == self.panes[0] else self.panes[0]
        if directory is None and target_pane.archive:
            self.status.setText(self.tr_key('zip_readonly'))
            return
        directory = Path(directory or target_pane.directory)
        if paths is None and pane.archive:
            if move:
                self.status.setText(self.tr_key('zip_readonly'))
                return
            self.extract_selected(directory)
            return
        paths = paths if paths is not None else [entry.path for entry in pane.selected()]
        if not paths:
            self.status.setText(self.tr_key('no_selection'))
            return
        mode = self.conflict_mode(paths, directory)
        if mode:
            self.run_operation(lambda: self.engine.transfer(paths, directory, move, mode))

    def drop_urls(self, urls, directory):
        paths = [Path(url.toLocalFile()) for url in urls if url.isLocalFile()]
        if len(paths) != len(urls):
            self.status.setText('Only local file URLs are supported.')
            return
        self.transfer(self.mode.currentData() == 'move', paths, directory)

    def copy_clipboard(self, move):
        if self.busy or self.active.archive:
            return
        paths = [entry.path for entry in self.active.selected()]
        if not paths:
            return
        mime = QMimeData()
        urls = [QUrl.fromLocalFile(str(path)) for path in paths]
        mime.setUrls(urls)
        mime.setData('x-special/gnome-copied-files',
                     (('cut' if move else 'copy') + '\n' + '\n'.join(url.toString(QUrl.FullyEncoded) for url in urls)).encode())
        mime.setData('application/x-kde-cutselection', b'1' if move else b'0')
        QApplication.clipboard().setMimeData(mime)
        self.status.setText(self.tr_key('cut' if move else 'clipboard'))

    def paste_clipboard(self):
        if self.busy or self.active.archive:
            return
        mime = QApplication.clipboard().mimeData()
        if mime is None:
            return
        gnome = bytes(mime.data('x-special/gnome-copied-files'))
        urls = mime.urls()
        if not urls and gnome:
            urls = [QUrl(line) for line in gnome.decode().splitlines()[1:]]
        if not urls or any(not url.isLocalFile() for url in urls):
            return
        move = gnome.startswith(b'cut\n') or bytes(mime.data('application/x-kde-cutselection')) == b'1'
        paths, directory = [Path(url.toLocalFile()) for url in urls], self.active.directory
        mode = self.conflict_mode(paths, directory)
        if mode:
            before = [u.toString() for u in urls]
            def finished(_):
                current = QApplication.clipboard().mimeData()
                if move and current and [u.toString() for u in current.urls()] == before:
                    QApplication.clipboard().clear()
            self.run_operation(lambda: self.engine.transfer(paths, directory, move, mode), finished)

    def selected_one(self):
        selected = self.active.selected()
        if len(selected) != 1:
            self.status.setText(self.tr_key('no_selection'))
            return None
        return selected[0]

    def rename_selected(self):
        if self.busy or self.active.archive:
            return
        entry = self.selected_one()
        if entry:
            name, accepted = QInputDialog.getText(self, self.tr_key('rename'), self.tr_key('name_prompt'), text=entry.name)
            if accepted and name != entry.name:
                self.run_operation(lambda: self.engine.rename(entry.path, name))

    def new_folder(self):
        if self.busy or self.active.archive:
            return
        directory = self.active.directory
        name, accepted = QInputDialog.getText(self, self.tr_key('new_folder'), self.tr_key('name_prompt'))
        if accepted:
            self.run_operation(lambda: self.engine.mkdir(directory, name))

    def trash_selected(self):
        if self.busy or self.active.archive:
            return
        paths = [entry.path for entry in self.active.selected()]
        if paths and QMessageBox.question(self, self.tr_key('trash'), self.tr_key('confirm_trash'),
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No) == QMessageBox.Yes:
            self.run_operation(lambda: self.engine.trash(paths))

    def zip_selected(self):
        if self.busy or self.active.archive:
            return
        paths = [entry.path for entry in self.active.selected()]
        if not paths:
            return
        directory = self.active.directory
        name, accepted = QInputDialog.getText(self, self.tr_key('zip'), self.tr_key('zip_name'), text='Archive.zip')
        if accepted and name and Path(name).name == name and name not in ('.', '..'):
            target = unique_path(directory, name if name.lower().endswith('.zip') else name + '.zip')
            self.run_operation(lambda: self.engine.make_zip(paths, target))

    def extract_selected(self, directory=None):
        if self.busy:
            return
        # QAction.triggered supplies a bool when connected directly.
        if isinstance(directory, bool):
            directory = None
        pane = self.active
        other = self.panes[1] if pane == self.panes[0] else self.panes[0]
        if directory is None and other.archive:
            self.status.setText(self.tr_key('zip_readonly'))
            return
        directory = Path(directory or other.directory)
        members = None
        archive = pane.archive
        if archive:
            selected = pane.selected()
            members = [entry.member for entry in selected] if selected else ([pane.prefix] if pane.prefix else None)
        else:
            entry = self.selected_one()
            if not entry or entry.path.suffix.lower() != '.zip':
                return
            archive = entry.path
        self.run_operation(lambda: self.engine.extract_zip(archive, directory, members))

    def undo(self, operation_id=None):
        if self.busy:
            return
        if isinstance(operation_id, bool):
            operation_id = None
        if self.engine.history:
            self.run_operation(lambda: self.engine.undo(operation_id))
        else:
            self.status.setText(self.tr_key('no_history'))

    def reload_history(self):
        from .history_ui import HistoryCard
        self.history_list.clear()
        for operation in reversed(self.engine.history):
            item = QListWidgetItem()
            item.setData(Qt.UserRole, operation['id'])
            card = HistoryCard(self, operation)
            item.setSizeHint(QSize(350, 300))
            self.history_list.addItem(item)
            self.history_list.setItemWidget(item, card)
        self.actions['undo'].setEnabled(bool(self.engine.history) and not self.busy)
        QTimer.singleShot(0, self.load_history_previews)

    def load_history_previews(self, *args):
        if not self.history_dock.isVisible():
            return
        visible = self.history_list.viewport().rect()
        for row in range(self.history_list.count()):
            item = self.history_list.item(row)
            if visible.intersects(self.history_list.visualItemRect(item)):
                card = self.history_list.itemWidget(item)
                if card:
                    card.request_preview()

    def toggle_history(self):
        self.history_dock.setVisible(not self.history_dock.isVisible())
        self.settings.setValue('history_visible', self.history_dock.isVisible())

    def choose_folder(self):
        path = QFileDialog.getExistingDirectory(self, self.tr_key('folder'), str(self.active.directory))
        if path:
            self.active.navigate(Path(path))

    def focus_path(self):
        self.active.path_edit.setFocus()
        self.active.path_edit.selectAll()

    def open_selected(self):
        entry = self.selected_one()
        if entry:
            self.active.open_entry(entry)

    def open_with_selected(self):
        entry = self.selected_one()
        if not entry or self.busy:
            return
        if entry.member and entry.directory:
            self.status.setText(self.tr_key('zip_readonly'))
            return
        from .integrations import invoke
        def choose():
            return invoke('open-with', str(self.materialize(entry)))
        def done(result):
            if not result['launched']:
                self.status.setText('Abgebrochen' if self.language == 'de' else 'Cancelled')
            elif entry.member:
                self.status.setText(self.tr_key('archive_copy'))
        self.run_operation(choose, done)

    def materialize(self, entry):
        if not entry.member:
            return entry.path
        cache = self.state_dir / 'previews'
        cache.mkdir(exist_ok=True, mode=0o700)
        directory = Path(tempfile.mkdtemp(dir=cache))
        target = directory / entry.name
        try:
            with zipfile.ZipFile(entry.path) as archive:
                checked_members(archive)
                info = archive.getinfo(entry.member)
                if info.file_size > 128 * 1024**2:
                    raise SafetyError('ZIP preview limit: 128 MiB')
                with archive.open(info) as inp, target.open('xb') as out:
                    shutil.copyfileobj(inp, out, 1024 * 1024)
            return target
        except Exception:
            shutil.rmtree(directory, ignore_errors=True)
            raise

    def open_entry(self, entry):
        if self.busy:
            return
        if media_kind(entry.name):
            self.open_media(entry)
            return
        def opened(path):
            if not QDesktopServices.openUrl(QUrl.fromLocalFile(str(path))):
                self.status.setText(self.tr_key('error') + ': ' + str(path))
            elif entry.member:
                self.status.setText(self.tr_key('archive_copy'))
        self.run_operation(lambda: self.materialize(entry), opened)

    def open_media(self, entry):
        pane = self.active
        entries = [pane.entry_at(pane.proxy.index(row, 0)) for row in range(pane.proxy.rowCount())]
        entries = [item for item in entries if not item.directory and media_kind(item.name)]
        if entry not in entries:
            entries = [entry]
        if getattr(self, 'preview_dialog', None) is not None and isValid(self.preview_dialog):
            self.preview_dialog.close()
        self.preview_dialog = MediaViewer(self, entries, entries.index(entry))
        self.preview_dialog.show()

    @staticmethod
    def is_image(path):
        formats = {bytes(value).decode('ascii').lower() for value in QImageReader.supportedImageFormats()}
        return Path(path).suffix.lower().lstrip('.') in formats | {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tif', 'tiff', 'svg', 'heic', 'avif'}

    def preview_selected(self):
        entry = self.selected_one()
        if not entry or entry.directory or self.busy:
            return
        if media_kind(entry.name):
            self.open_media(entry)
        else:
            self.run_operation(lambda: self.materialize(entry), self.show_preview)

    def show_preview(self, path):
        dialog = QDialog(self)
        dialog.setAttribute(Qt.WA_DeleteOnClose)
        dialog.setWindowTitle(path.name)
        dialog.resize(850, 650)
        layout = QVBoxLayout(dialog)
        reader = QImageReader(str(path))
        reader.setAllocationLimit(64)
        reader.setAutoTransform(True)
        if reader.canRead() or self.is_image(path):
            if reader.size().isValid():
                reader.setScaledSize(reader.size().scaled(QSize(1600, 1200), Qt.KeepAspectRatio))
            image = reader.read()
            label = QLabel()
            label.setAlignment(Qt.AlignCenter)
            if image.isNull():
                label.setText(reader.errorString())
            else:
                label.setPixmap(QPixmap.fromImage(image))
            scroll = QScrollArea()
            scroll.setWidget(label)
            scroll.setWidgetResizable(True)
            layout.addWidget(scroll)
        else:
            area = QTextEdit()
            area.setReadOnly(True)
            try:
                with path.open('rb') as stream:
                    content = stream.read(2 * 1024**2)
                area.setPlainText(content.decode('utf-8') if b'\0' not in content else self.tr_key('preview_large'))
            except (UnicodeError, OSError):
                area.setPlainText(self.tr_key('open_external'))
            layout.addWidget(area)
        button = QPushButton(self.tr_key('open_external'))
        button.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(path))))
        layout.addWidget(button)
        self.preview_dialog = dialog
        dialog.show()

    def info(self):
        entry = self.selected_one()
        if entry:
            from .properties_ui import PropertiesDialog
            self.properties_dialog = PropertiesDialog(self, entry)
            self.properties_dialog.show()

    def help(self):
        QMessageBox.information(self, 'OpenCommander · Linux', self.tr_key('help_text'))

    def refresh_all(self):
        for pane in self.panes:
            pane.refresh()

    def toggle_hidden(self):
        self.hidden = not self.hidden
        self.hidden_checkbox.setChecked(self.hidden)
        self.settings.setValue('hidden', self.hidden)
        self.actions['hidden'].setChecked(self.hidden)
        for pane in self.panes:
            pane.tree_model.setFilter(QDir.AllDirs | QDir.NoDotAndDotDot | (QDir.Hidden if self.hidden else QDir.Filter(0)))
        self.refresh_all()

    def change_language(self):
        self.language = self.language_combo.currentData()
        self.settings.setValue('language', self.language)
        self.retranslate()

    def retranslate(self):
        for key, action in self.actions.items():
            action.setText(self.tr_key(key))
            action.setToolTip(self.tr_key(key) + (f' ({action.shortcut().toString()})' if not action.shortcut().isEmpty() else ''))
        self.actions['open_with'].setText('Öffnen mit …' if self.language == 'de' else 'Open with …')
        self.mode.set_labels(self.tr_key('copy'), self.tr_key('move'))
        self.hidden_checkbox.setText(self.tr_key('hidden'))
        self.mode_label.setText('Aktion:' if self.language == 'de' else 'Action:')
        self.theme_button.setText(self.tr_key('dark'))
        self.theme_button.setChecked(self.dark)
        self.cancel_button.setText(self.tr_key('cancel'))
        self.history_dock.setWindowTitle(self.tr_key('history'))
        for pane in self.panes:
            pane.retranslate()
        self.activate(self.active or self.panes[0])
        self.update_places()
        self.reload_history()

    def scan_integrations(self):
        if self.integration_scanning:
            return
        from .integrations import invoke
        self.integration_scanning = True
        task = Task(invoke)
        self.tasks.add(task)
        def done(value, error):
            self.tasks.discard(task)
            self.integration_scanning = False
            if not error and value != self.integration_locations:
                self.integration_locations = value
                self.update_places()
        task.signals.result.connect(done)
        self.pool.start(task)

    def connections(self):
        from .connections_ui import ConnectionsDialog
        if not hasattr(self, 'connections_dialog'):
            self.connections_dialog = ConnectionsDialog(self)
        self.connections_dialog.timer.start(5000)
        self.connections_dialog.show()
        self.connections_dialog.raise_()
        self.connections_dialog.refresh()

    def update_places(self):
        while self.places.count():
            item = self.places.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        locations = [(self.tr_key('root'), Path('/')), (self.tr_key('home'), Path.home())]
        downloads = Path(QStandardPaths.writableLocation(QStandardPaths.DownloadLocation))
        if downloads.is_dir():
            locations.append((self.tr_key('downloads'), downloads))
        locations += [(path.name, path) for path in mounted_locations() + cloud_locations()]
        locations += [(item['name'], Path(item['path'])) for item in self.integration_locations if item['path']]
        self.known_locations = locations
        locations = [(name, Path(path)) for name, path in configured_locations(locations, self.location_preferences)]
        connect = QPushButton('Verbindungen …' if self.language == 'de' else 'Connections …')
        connect.clicked.connect(self.connections)
        self.places.addWidget(connect)
        seen = set()
        for name, path in locations:
            if path in seen:
                continue
            seen.add(path)
            button = QPushButton(name)
            button.setToolTip(str(path))
            button.setObjectName('place')
            button.clicked.connect(lambda checked=False, path=path: self.active.navigate(path))
            self.places.addWidget(button)
        self.places.addStretch()

    def location_settings(self):
        if self.busy:
            return
        from .location_settings import LocationSettingsDialog
        self.location_settings_dialog = LocationSettingsDialog(self, getattr(self, 'known_locations', []))
        self.location_settings_dialog.exec()

    def toggle_theme(self):
        self.dark = not self.dark
        self.settings.setValue('dark', self.dark)
        self.apply_theme()
        self.activate(self.active)
        self.theme_button.setText(self.tr_key('dark'))
        self.theme_button.setChecked(self.dark)

    def apply_theme(self):
        bg, panel, inset, fg, muted, border, selection = (
            ('#171e2d', '#242e40', '#1c2638', '#e8eef9', '#afbed3', '#40516b', '#334f76') if self.dark else
            ('#eaf0fa', '#ffffff', '#f0f4fc', '#202c43', '#53647c', '#c9d6e8', '#dceaff'))
        blue, green, purple, gold, red = (
            ('#88baff', '#79dcb9', '#cfadff', '#f1c36d', '#ff919c') if self.dark else
            ('#185bb5', '#147454', '#753bb0', '#885400', '#b42338'))
        check_icon = (Path(__file__).parent / 'assets/check.svg').as_posix()
        self.setStyleSheet(f'''
            QMainWindow, QDialog, QWidget#places, QScrollArea {{ background: {bg}; border: none; }}
            QWidget {{ color: {fg}; font-family: "DejaVu Sans"; font-size: 12px; }}
            QFrame#pane {{ background: {panel}; border: 1px solid {border}; border-radius: 10px; }}
            QFrame#pane[side="1"] {{ border-top: 3px solid {blue}; }}
            QFrame#pane[side="2"] {{ border-top: 3px solid {green}; }}
            QWidget#historyCard {{ background: {inset}; border: 1px solid {border}; border-radius: 8px; }}
            QLabel {{ background: transparent; }}
            QLabel#brand {{ color: {blue}; font-size: 25px; font-weight: 700; }}
            QLabel#badge {{ color: #6caaff; background: {inset}; padding: 5px 9px; border-radius: 4px; font-size: 10px; font-weight: 700; }}
            QLabel#muted {{ color: {muted}; font-size: 11px; }}
            QLineEdit, QComboBox {{ background: {inset}; border: 1px solid {border}; padding: 7px; border-radius: 5px; selection-background-color: {selection}; }}
            QPushButton, QToolButton {{ background: {panel}; border: 1px solid {border}; border-radius: 5px; padding: 7px 10px; }}
            QPushButton:hover, QToolButton:hover, QToolButton:checked {{ background: {selection}; }}
            QPushButton:disabled, QToolButton:disabled {{ color: {muted}; }}
            QToolButton[actionKind="copy"], QToolButton[actionKind="preview"] {{ color: {blue}; border-bottom: 2px solid {blue}; }}
            QToolButton[actionKind="move"], QToolButton[actionKind="new_folder"] {{ color: {green}; border-bottom: 2px solid {green}; }}
            QToolButton[actionKind="zip"], QToolButton[actionKind="extract"] {{ color: {purple}; border-bottom: 2px solid {purple}; }}
            QToolButton[actionKind="rename"], QToolButton[actionKind="undo"] {{ color: {gold}; border-bottom: 2px solid {gold}; }}
            QToolButton[actionKind="trash"] {{ color: {red}; border-bottom: 2px solid {red}; }}
            QToolButton[actionKind="new_folder"] {{ background: {'#173f2a' if self.dark else '#e9f8ef'}; color: {green}; }}
            QToolButton[actionKind="rename"], QToolButton[actionKind="preview"] {{ background: {'#1f344d' if self.dark else '#e8f1ff'}; color: {blue}; }}
            QToolButton[actionKind="trash"] {{ background: {'#51231f' if self.dark else '#ffe4e0'}; color: {red}; }}
            QToolButton[actionKind="zip"], QToolButton[actionKind="extract"] {{ background: {'#4b3514' if self.dark else '#fff4d8'}; color: {gold}; }}
            QToolButton:disabled {{ color: {muted}; border-bottom: 1px solid {border}; }}
            QPushButton#place {{ background: {inset}; color: {blue}; padding: 5px 10px; }}
            QCheckBox {{ spacing: 7px; padding: 4px; }}
            QCheckBox::indicator {{ width: 18px; height: 18px; border: 1px solid {border}; border-radius: 4px; background: {inset}; }}
            QCheckBox::indicator:checked {{ background: {green}; border: 2px solid {green}; image: url("{check_icon}"); }}
            QCheckBox#modeSwitch::indicator {{ width: 42px; height: 22px; border-radius: 11px; background: {blue}; }}
            QCheckBox#modeSwitch::indicator:checked {{ background: {green}; }}
            QToolBar {{ background: transparent; border: none; spacing: 6px; }}
            QTreeView, QTableView, QListWidget, QTextEdit {{ background: {panel}; alternate-background-color: {inset}; border: none; selection-background-color: {selection}; selection-color: {fg}; }}
            QTreeView::item {{ height: 29px; }}
            QHeaderView::section {{ background: {inset}; color: {muted}; border: none; padding: 8px 5px; font-size: 11px; }}
            QSplitter::handle {{ background: {bg}; width: 8px; }}
            QScrollBar:vertical {{ background: {inset}; width: 10px; }}
            QScrollBar::handle:vertical {{ background: {border}; min-height: 24px; border-radius: 4px; }}
            QProgressBar {{ border: 1px solid {border}; border-radius: 4px; height: 8px; }}
            QProgressBar::chunk {{ background: #6caaff; }}
            QMenu, QComboBox QAbstractItemView {{ background: {panel}; color: {fg}; }}
            QMenu::item:selected {{ background: {selection}; }}
        ''')

    def closeEvent(self, event):
        if self.busy or (hasattr(self, 'connections_dialog') and self.connections_dialog.pending):
            self.status.setText(self.tr_key('quit_busy'))
            event.ignore()
            return
        self.integration_timer.stop()
        if hasattr(self, 'connections_dialog'):
            self.connections_dialog.timer.stop()
        # Listing workers must finish before their signal receivers are destroyed.
        if getattr(self, 'preview_dialog', None) is not None and isValid(self.preview_dialog):
            self.preview_dialog.close()
        self.thumbnails.pool.waitForDone()
        self.pool.waitForDone()
        self.settings.setValue('geometry', self.saveGeometry())
        self.settings.sync()
        event.accept()
