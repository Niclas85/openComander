from PySide6.QtCore import Signal, QSize, Qt
from PySide6.QtGui import QPainter, QColor
from PySide6.QtWidgets import QWidget, QHBoxLayout, QLabel, QCheckBox


class Switch(QCheckBox):
    def sizeHint(self):
        return QSize(52, 28)

    def hitButton(self, position):
        return self.rect().contains(position)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor('#238465' if self.isChecked() else '#326ab2'))
        painter.drawRoundedRect(2, 2, 48, 24, 12, 12)
        painter.setBrush(QColor('#ffffff'))
        painter.drawEllipse(28 if self.isChecked() else 6, 6, 16, 16)
        if self.hasFocus():
            painter.setPen(QColor('#e3b65d'))
            painter.setBrush(Qt.NoBrush)
            painter.drawRoundedRect(1, 1, 50, 26, 13, 13)


class ModeToggle(QWidget):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        self.copy_label, self.move_label = QLabel(), QLabel()
        self.switch = Switch()
        self.switch.setFixedSize(52, 28)
        self.switch.setObjectName('modeSwitch')
        self.switch.toggled.connect(self.changed)
        for widget in (self.copy_label, self.switch, self.move_label):
            row.addWidget(widget)

    def set_labels(self, copy, move):
        self.copy_label.setText(copy)
        self.move_label.setText(move)
        self.switch.setAccessibleName(copy + ' / ' + move)

    def currentData(self):
        return 'move' if self.switch.isChecked() else 'copy'

    def setCurrentIndex(self, index):
        self.switch.setChecked(index == 1)
