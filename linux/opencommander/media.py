"""Bounded asynchronous thumbnails and an in-app image/audio/video browser."""
from collections import OrderedDict
from pathlib import Path
import shutil
import subprocess

from PySide6.QtCore import Qt, QSize, QUrl, QThreadPool
from PySide6.QtGui import QImageReader, QImage, QPixmap, QIcon, QShortcut, QKeySequence
from PySide6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
                              QStackedWidget, QSlider)
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput
from PySide6.QtMultimediaWidgets import QVideoWidget
from .desktop import host_environment

IMAGES = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.svg', '.heic', '.avif'}
VIDEOS = {'.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.mpeg', '.mpg'}
AUDIO = {'.mp3', '.wav', '.ogg', '.flac', '.m4a', '.aac', '.opus', '.wma'}


def media_kind(path):
    suffix = Path(path).suffix.lower()
    if suffix in IMAGES or suffix.lstrip('.') in {bytes(x).decode().lower() for x in QImageReader.supportedImageFormats()}:
        return 'image'
    return 'video' if suffix in VIDEOS else 'audio' if suffix in AUDIO else None


def read_image(path, size):
    reader = QImageReader(str(path))
    reader.setAllocationLimit(64)
    reader.setAutoTransform(True)
    original = reader.size()
    if original.isValid() and (original.width() > size.width() or original.height() > size.height()):
        reader.setScaledSize(original.scaled(size, Qt.KeepAspectRatio))
    image = reader.read()
    if image.isNull():
        raise ValueError(reader.errorString())
    return image.scaled(size, Qt.KeepAspectRatio, Qt.SmoothTransformation)


def thumbnail(path, kind):
    if kind == 'image':
        return read_image(path, QSize(96, 64))
    if kind == 'video' and shutil.which('ffmpeg'):
        result = subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-threads', '1',
                                 '-i', str(path), '-frames:v', '1', '-vf',
                                 'scale=96:64:force_original_aspect_ratio=decrease',
                                 '-threads', '1', '-f', 'image2pipe', '-vcodec', 'png', '-'],
                                capture_output=True, timeout=8, check=True, env=host_environment())
        return QImage.fromData(result.stdout)
    return QImage()


class ThumbnailCache:
    def __init__(self, main):
        self.main = main
        self.pool = QThreadPool(main)
        self.pool.setMaxThreadCount(2)
        self.cache = OrderedDict()
        self.pending = set()

    def get(self, entry, model, row):
        kind = media_kind(entry.name)
        if entry.directory or entry.error or entry.member or kind not in ('image', 'video'):
            return None
        key = (str(entry.path), entry.size, entry.modified)
        if key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]
        # Only visible cells request icons; never queue an entire directory.
        if key in self.pending or len(self.pending) >= 8:
            return None
        from .ui import Task
        self.pending.add(key)
        task = Task(lambda: thumbnail(entry.path, kind))
        self.main.tasks.add(task)
        def done(image, error):
            self.pending.discard(key)
            self.main.tasks.discard(task)
            self.cache[key] = QIcon(QPixmap.fromImage(image)) if not error and not image.isNull() else None
            while len(self.cache) > 256:
                self.cache.popitem(last=False)
            # A changed directory/sort must not attach the image to the old row.
            for pane in self.main.panes:
                pane.table.viewport().update()
        task.signals.result.connect(done)
        self.pool.start(task)
        return None


class MediaViewer(QDialog):
    def __init__(self, main, entries, index):
        super().__init__(main)
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.main, self.entries, self.index = main, entries, index
        self.generation = 0
        self.closed = False
        self.current_image = QImage()
        self.resize(1040, 760)
        layout = QVBoxLayout(self)
        self.caption = QLabel()
        layout.addWidget(self.caption)
        self.stack = QStackedWidget()
        self.image_label = QLabel()
        self.image_label.setAlignment(Qt.AlignCenter)
        self.image_label.setMinimumSize(1, 1)
        self.stack.addWidget(self.image_label)
        self.video = QVideoWidget()
        self.stack.addWidget(self.video)
        layout.addWidget(self.stack, 1)
        self.message = QLabel()
        self.message.setWordWrap(True)
        layout.addWidget(self.message)
        self.player = QMediaPlayer(self)
        self.audio = QAudioOutput(self)
        self.audio.setVolume(0.6)
        self.player.setAudioOutput(self.audio)
        self.player.setVideoOutput(self.video)
        self.player.errorOccurred.connect(lambda *args: self.message.setText(self.player.errorString()))
        self.player.playbackStateChanged.connect(lambda state: self.play.setText('Ⅱ' if state == QMediaPlayer.PlayingState else '▶'))
        controls = QHBoxLayout()
        self.previous = QPushButton('←')
        self.previous.setAccessibleName('Previous media')
        self.next = QPushButton('→')
        self.next.setAccessibleName('Next media')
        self.play = QPushButton('▶')
        self.previous.clicked.connect(lambda: self.step(-1))
        self.next.clicked.connect(lambda: self.step(1))
        self.play.clicked.connect(self.toggle_play)
        self.seek = QSlider(Qt.Horizontal)
        self.seek.setAccessibleName('Playback position')
        self.seek.sliderMoved.connect(self.player.setPosition)
        self.player.durationChanged.connect(lambda duration: self.seek.setRange(0, min(duration, 2147483647)))
        self.player.positionChanged.connect(lambda position: self.seek.setValue(position) if not self.seek.isSliderDown() else None)
        for widget in (self.previous, self.play, self.seek, self.next):
            controls.addWidget(widget)
        layout.addLayout(controls)
        for key, callback in [('Left', lambda: self.step(-1)), ('Right', lambda: self.step(1)), ('Space', self.toggle_play)]:
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.setContext(Qt.WindowShortcut)
            shortcut.activated.connect(callback)
        self.load()

    def step(self, delta):
        index = self.index + delta
        if 0 <= index < len(self.entries):
            self.index = index
            self.load()

    def load(self):
        from .ui import Task
        self.generation += 1
        generation = self.generation
        entry = self.entries[self.index]
        kind = media_kind(entry.name)
        self.player.stop()
        self.player.setSource(QUrl())
        self.current_image = QImage()
        self.image_label.clear()
        self.stack.setCurrentWidget(self.image_label)
        self.message.setText('Laden …' if self.main.language == 'de' else 'Loading …')
        self.setWindowTitle(entry.name)
        self.caption.setText(f'{self.index + 1} / {len(self.entries)}  ·  {entry.name}')
        self.previous.setEnabled(self.index > 0)
        self.next.setEnabled(self.index + 1 < len(self.entries))
        self.play.setEnabled(False)
        self.seek.setEnabled(False)
        self.play.setVisible(kind == 'video')
        self.seek.setVisible(kind == 'video')
        def work():
            if self.closed or generation != self.generation:
                return None
            path = self.main.materialize(entry)
            return path, read_image(path, QSize(2560, 1600)) if kind == 'image' else None
        task = Task(work)
        self.main.tasks.add(task)
        def done(value, error):
            self.main.tasks.discard(task)
            if self.closed or generation != self.generation:
                return
            self.message.setText(str(error) if error else '')
            if error:
                return
            path, image = value
            if kind == 'image':
                self.current_image = image
                self.fit_image()
            else:
                self.stack.setCurrentWidget(self.video if kind == 'video' else self.image_label)
                if kind == 'audio':
                    self.image_label.setText('♫\n' + entry.name)
                self.play.setEnabled(True)
                self.seek.setEnabled(True)
                self.player.setSource(QUrl.fromLocalFile(str(path)))
                self.player.play()
        task.signals.result.connect(done)
        self.main.pool.start(task)

    def fit_image(self):
        if not self.current_image.isNull():
            self.image_label.setPixmap(QPixmap.fromImage(self.current_image).scaled(
                self.stack.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.fit_image()

    def toggle_play(self):
        if self.play.isEnabled():
            self.player.pause() if self.player.playbackState() == QMediaPlayer.PlayingState else self.player.play()

    def shutdown(self):
        self.closed = True
        self.generation += 1
        self.player.stop()
        self.player.setSource(QUrl())

    def closeEvent(self, event):
        self.shutdown()
        super().closeEvent(event)

    def reject(self):
        self.shutdown()
        super().reject()
