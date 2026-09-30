"""Refresh properties asynchronously; never present directory inode size as content size."""
from datetime import datetime
from pathlib import Path
import stat
import os
import pwd
import grp
import zipfile
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QDialog, QVBoxLayout, QTextEdit, QPushButton
from shiboken6 import isValid
from .integrations import invoke


def properties(entry):
    if entry.member:
        with zipfile.ZipFile(entry.path) as archive:
            if entry.directory:
                members = [i for i in archive.infolist() if i.filename.startswith(entry.member)]
                return dict(name=entry.name, path=str(entry.path) + '!/' + entry.member,
                            type='ZIP directory', directory=True, archive_bytes=sum(i.file_size for i in members if not i.is_dir()),
                            archive_entries=len(members))
            info = archive.getinfo(entry.member)
            return dict(name=entry.name, path=str(entry.path) + '!/' + entry.member,
                        type='ZIP file', directory=False, size=info.file_size,
                        compressed=info.compress_size, archive_modified=str(info.date_time))
    try:
        return invoke('properties', str(entry.path))
    except (RuntimeError, FileNotFoundError):
        from .filesystem import remote_location
        if remote_location(entry.path):
            raise
        info = entry.path.lstat()
        try:
            owner = pwd.getpwuid(info.st_uid).pw_name
        except KeyError:
            owner = str(info.st_uid)
        try:
            group = grp.getgrgid(info.st_gid).gr_name
        except KeyError:
            group = str(info.st_gid)
        return dict(name=entry.name, path=str(entry.path), uri=entry.path.absolute().as_uri(),
                    directory=stat.S_ISDIR(info.st_mode), type='directory' if stat.S_ISDIR(info.st_mode) else 'file',
                    size=info.st_size, modified=info.st_mtime, accessed=info.st_atime,
                    created=getattr(info, 'st_birthtime', None), owner=owner, group=group,
                    mode=info.st_mode, read=os.access(entry.path, os.R_OK, follow_symlinks=False),
                    write=os.access(entry.path, os.W_OK, follow_symlinks=False),
                    link=os.readlink(entry.path) if stat.S_ISLNK(info.st_mode) else None)


def format_properties(data, de=True):
    from .ui import human_size
    unknown = 'Nicht vom Dateisystem gemeldet' if de else 'Not reported by filesystem'
    def value(key):
        result = data.get(key)
        if result is None or result == '':
            return unknown
        if isinstance(result, bool):
            return ('Ja' if de else 'Yes') if result else ('Nein' if de else 'No')
        return str(result)
    def date(key):
        result = data.get(key)
        if result is None or result == 0:
            return unknown
        try:
            return datetime.fromtimestamp(result).strftime('%d.%m.%Y %H:%M:%S')
        except (OverflowError, OSError, ValueError):
            return unknown
    def size(key):
        result = data.get(key)
        return unknown if result is None else f'{human_size(result)} ({result:,} Bytes)'
    rows = [(('Name', 'Name'), value('name')), (('Pfad', 'Path'), value('path')),
            (('Adresse', 'Address'), value('uri')), (('Typ', 'Type'), value('type')),
            (('Dateiformat', 'Content type'), value('content_type')),
            (('Größe', 'Size'), ('Ordnerinhalt nicht rekursiv berechnet' if de else 'Folder contents not recursively calculated') if data.get('directory') else size('size')),
            (('Geändert', 'Modified'), date('modified')), (('Erstellt', 'Created'), date('created')),
            (('Letzter Zugriff', 'Accessed'), date('accessed')),
            (('Eigentümer', 'Owner'), value('owner')), (('Gruppe', 'Group'), value('group')),
            (('Lesen erlaubt', 'Read permitted'), value('read')), (('Schreiben erlaubt', 'Write permitted'), value('write')),
            (('Dateisystem', 'Filesystem'), value('filesystem')), (('Schreibgeschützt', 'Read-only filesystem'), value('readonly')),
            (('Freier Speicher', 'Free space'), size('filesystem_free')),
            (('Gesamter Speicher', 'Total space'), size('filesystem_size'))]
    if data.get('mode') is not None:
        rows.append((('POSIX-Rechte (Provider-Angabe)', 'POSIX mode (provider reported)'), stat.filemode(data['mode'])))
    if data.get('link'):
        rows.append((('Linkziel', 'Link target'), data['link']))
    if 'archive_bytes' in data:
        rows.append((('Inhalt im ZIP', 'ZIP contents'), size('archive_bytes')))
    if 'compressed' in data:
        rows.append((('Komprimiert', 'Compressed'), size('compressed')))
    if 'archive_modified' in data:
        rows.append((('ZIP-Zeitstempel', 'ZIP timestamp'), data['archive_modified']))
    note = ('NAS-/Cloud-Rechte und Zeitstempel stammen vom jeweiligen Provider; POSIX-Rechte können synthetisch sein. Nicht gemeldete Werte werden nicht als 0 oder „Nein“ ausgegeben.' if de else
            'NAS/cloud permissions and timestamps are provider reported; POSIX modes may be synthetic. Missing values are not shown as zero or No.')
    return '\n\n'.join(f'{labels[0 if de else 1]}: {text}' for labels, text in rows) + '\n\n' + note


class PropertiesDialog(QDialog):
    def __init__(self, main, entry):
        super().__init__(main)
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.setWindowTitle(main.tr_key('info') + ' · ' + entry.name)
        self.resize(680, 720)
        layout = QVBoxLayout(self)
        self.details = QTextEdit()
        self.details.setReadOnly(True)
        self.details.setPlainText('Laden …' if main.language == 'de' else 'Loading …')
        layout.addWidget(self.details)
        if entry.directory and not entry.member and not entry.link:
            calculate = QPushButton('Ordnergröße berechnen' if main.language == 'de' else 'Calculate folder size')
            layout.addWidget(calculate)
            def calculate_size():
                from .ui import Task
                calculate.setEnabled(False)
                task = Task(lambda: invoke('directory-size', str(entry.path)))
                def counted(value, error):
                    if not isValid(self.details):
                        return
                    calculate.setEnabled(True)
                    if error:
                        self.details.append('')
                        self.details.insertPlainText(str(error))
                        return
                    from .ui import human_size
                    de = main.language == 'de'
                    status = ('Vollständig' if de else 'Complete') if value['complete'] else ('Unvollständig (Grenze oder Zugriffsfehler)' if de else 'Incomplete (limit or access error)')
                    self.details.append(f"\n{status}: {human_size(value['bytes'])} ({value['bytes']} Bytes)\n"
                                        f"{value['files']} {'Dateien' if de else 'files'}, {value['directories']} {'Ordner' if de else 'folders'}, "
                                        f"{value['errors']} {'Zugriffsfehler' if de else 'access errors'}")
                task.signals.result.connect(counted)
                main.start_background(task)
            calculate.clicked.connect(calculate_size)
        close = QPushButton('Schließen' if main.language == 'de' else 'Close')
        close.clicked.connect(self.close)
        layout.addWidget(close)
        from .ui import Task
        task = Task(lambda: properties(entry))
        def done(value, error):
            if isValid(self.details):
                self.details.setPlainText(str(error) if error else format_properties(value, main.language == 'de'))
        task.signals.result.connect(done)
        main.start_background(task)
