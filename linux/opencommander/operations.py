"""Recoverable local file operations. No shell commands and no following symlinks.

Each copy is prepared on the target volume and published with RENAME_NOREPLACE.
A failed source cleanup must retain the complete destination. History is persistent,
but this is not a filesystem journal or a guarantee against power loss.
"""
from __future__ import annotations

import sys
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import threading
import time
import uuid
import zipfile


class SafetyError(Exception):
    pass


class Cancelled(SafetyError):
    pass


class CleanupError(SafetyError):
    """The destination is complete and must not be rolled back."""


def exists(path: Path) -> bool:
    return os.path.lexists(path)


def rename_new(source: Path, target: Path):
    """Linux atomic no-replace rename, including dangling symlink conflicts."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(target), 1):
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), str(target))


def remove_tree(path: Path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def fingerprint(path: Path) -> str:
    digest = hashlib.sha256()

    def field(value):
        data = str(value).encode('utf-8', 'surrogateescape')
        digest.update(str(len(data)).encode() + b':' + data)

    def visit(item):
        info = item.lstat()
        field(item.name)
        for value in (info.st_dev, info.st_ino, info.st_mode, info.st_mtime_ns):
            field(value)
        if stat.S_ISLNK(info.st_mode):
            field(os.readlink(item))
        elif stat.S_ISDIR(info.st_mode):
            children = sorted(item.iterdir(), key=lambda p: p.name)
            field(len(children))
            for child in children:
                visit(child)
        elif stat.S_ISREG(info.st_mode):
            content = hashlib.sha256()
            with item.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    content.update(block)
            digest.update(content.digest())
        else:
            raise SafetyError(f'Unsupported file: {item}')
    visit(path)
    return digest.hexdigest()


def safe_snapshot(path):
    try:
        return fingerprint(path)
    except (OSError, SafetyError):
        return None  # A failed verification never invalidates a completed transfer.


def unique_path(directory: Path, name: str) -> Path:
    candidate = directory / name
    number = 2
    while exists(candidate):
        p = Path(name)
        candidate = directory / f'{p.stem} ({number}){p.suffix}'
        number += 1
    return candidate


def selected_roots(paths):
    # Preserve symlinks as objects; resolve only the parent for containment checks.
    unique = list(dict.fromkeys(Path(os.path.abspath(p)) for p in paths))
    return [p for p in unique if not any(q != p and not q.is_symlink() and q in p.parents for q in unique)]


def validate_target(source, directory):
    if source.is_dir() and not source.is_symlink():
        origin, target = source.resolve(), directory.resolve()
        if origin == target or origin in target.parents:
            raise SafetyError(f'A folder cannot be copied into itself: {source}')


class FileEngine:
    def __init__(self, state_dir: Path):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.history_file = self.state_dir / 'history.json'
        self.history = []
        self.load_error = None
        self.cancel = threading.Event()
        self.progress = lambda count, name: None
        self.bytes_done = 0
        if self.history_file.exists():
            try:
                data = json.loads(self.history_file.read_text())
                if data.get('version') != 1 or not isinstance(data['history'], list):
                    raise ValueError('Unsupported history format')
                self.history = data['history']
            except (OSError, ValueError, KeyError) as error:
                # Keep the original file; do not silently overwrite unreadable recovery metadata.
                self.load_error = str(error)

    def save(self):
        if self.load_error:
            raise SafetyError(f'History could not be read: {self.history_file}\n{self.load_error}')
        temp = self.state_dir / f'.history-{uuid.uuid4().hex}'
        try:
            with temp.open('x', encoding='utf-8') as stream:
                os.chmod(temp, 0o600)
                json.dump({'version': 1, 'history': self.history}, stream, ensure_ascii=True, indent=2)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, self.history_file)
        finally:
            temp.unlink(missing_ok=True)

    def begin(self, label):
        self.save()  # Verify recovery storage before modifying user files.
        self.bytes_done = 0
        operation = {'id': uuid.uuid4().hex, 'label': label, 'time': time.time(), 'records': []}
        self.history.append(operation)
        return operation

    def record(self, operation, source, destination, kind, backup=None):
        operation['records'].append({'source': str(source), 'destination': str(destination),
            'kind': kind, 'backup': str(backup) if backup else None,
            'snapshot': safe_snapshot(destination), 'reverted': False})
        self.save()

    def finish(self, operation):
        error = sys.exc_info()[1]
        if error is not None:
            operation['error'] = str(error)
        if not operation['records']:
            self.history.remove(operation)
        self.save()

    def check_cancel(self):
        if self.cancel.is_set():
            raise Cancelled('Cancelled')

    def copy_file(self, source, target):
        self.check_cancel()
        info = source.lstat()
        if stat.S_ISLNK(info.st_mode):
            os.symlink(os.readlink(source), target)
        elif stat.S_ISDIR(info.st_mode):
            target.mkdir()
            for item in sorted(source.iterdir()):
                self.copy_file(item, target / item.name)
            shutil.copystat(source, target, follow_symlinks=False)
        elif stat.S_ISREG(info.st_mode):
            with source.open('rb') as inp, target.open('xb') as out:
                for block in iter(lambda: inp.read(1024 * 1024), b''):
                    self.check_cancel()
                    out.write(block)
                    self.bytes_done += len(block)
                    self.progress(self.bytes_done, source.name)
                out.flush()
                os.fsync(out.fileno())
            shutil.copystat(source, target, follow_symlinks=False)
        else:
            raise SafetyError(f'Unsupported file: {source}')

    def publish(self, payload: Path, target: Path, replace=False):
        backup = None
        if exists(target):
            if not replace:
                raise FileExistsError(str(target))
            backup = payload.parent / 'previous'
            rename_new(target, backup)
        try:
            rename_new(payload, target)
        except Exception as error:
            if backup:
                try:
                    rename_new(backup, target)
                except OSError as recovery_error:
                    raise SafetyError(f'{error}\nRecovery retained: {backup}\n{recovery_error}') from error
            raise
        return backup

    def copy_to(self, source: Path, target: Path, replace=False):
        staging = Path(tempfile.mkdtemp(prefix='.OpenCommanderTransfer-', dir=target.parent))
        try:
            payload = staging / 'payload'
            self.copy_file(source, payload)
            self.check_cancel()
            return self.publish(payload, target, replace)
        finally:
            # Never discard a displaced original, even after a failed rollback.
            if not exists(staging / 'previous'):
                shutil.rmtree(staging, ignore_errors=True)

    def move_to(self, source, target, replace=False):
        if exists(target):
            if not replace:
                raise FileExistsError(str(target))
            # A replacement copy must finish before touching either original.
            backup = self.copy_to(source, target, True)
        else:
            try:
                rename_new(source, target)
                return None
            except OSError as error:
                if error.errno != errno.EXDEV:
                    raise
            backup = self.copy_to(source, target)
        try:
            remove_tree(source)
        except OSError as error:
            raise CleanupError(f'Source cleanup failed. Complete copy retained: {target}'
                + (f'\nPrevious version: {backup}' if backup else '')) from error
        return backup

    def protect_state(self, paths):
        for path in paths:
            path = Path(path)
            if not path.is_symlink():
                resolved = path.resolve()
                state = self.state_dir.resolve()
                if resolved == state or resolved in state.parents or state in resolved.parents:
                    raise SafetyError(f'The active recovery profile cannot be modified: {path}')

    def transfer(self, paths, directory, move=False, conflict='keep'):
        directory = Path(directory)
        if not directory.is_dir():
            raise NotADirectoryError(str(directory))
        sources = selected_roots(paths)
        if move:
            self.protect_state(sources)
        # Only forbid writing within the profile, not to its ancestors.
        if directory.resolve() == self.state_dir.resolve() or self.state_dir.resolve() in directory.resolve().parents:
            raise SafetyError('The recovery profile cannot be a destination')
        for source in sources:
            validate_target(source, directory)
        operation = self.begin('move' if move else 'copy')
        try:
            for source in sources:
                self.check_cancel()
                preferred = directory / source.name
                if source == preferred:
                    if move:
                        continue
                    target = unique_path(directory, source.name)
                else:
                    target = unique_path(directory, source.name) if conflict == 'keep' else preferred
                action = self.move_to if move else self.copy_to
                backup = action(source, target, conflict == 'replace')
                self.record(operation, source, target, 'move' if move else 'copy', backup)
        finally:
            self.finish(operation)
        return operation

    def rename(self, source, name):
        source = Path(source)
        self.protect_state([source])
        if not name or name in ('.', '..') or '/' in name or '\0' in name:
            raise SafetyError('Invalid name')
        target = source.parent / name
        operation = self.begin('rename')
        try:
            rename_new(source, target)
            self.record(operation, source, target, 'move')
        finally:
            self.finish(operation)

    def mkdir(self, directory, name):
        if not name or name in ('.', '..') or '/' in name or '\0' in name:
            raise SafetyError('Invalid name')
        target = Path(directory) / name
        operation = self.begin('mkdir')
        try:
            target.mkdir()
            self.record(operation, target, target, 'copy')
        finally:
            self.finish(operation)

    def trash(self, paths):
        paths = selected_roots(paths)
        self.protect_state(paths)
        operation = self.begin('trash')
        try:
            for source in selected_roots(paths):
                self.check_cancel()
                if source == Path('/'):
                    raise SafetyError('The filesystem root cannot be removed')
                root = Path(tempfile.mkdtemp(prefix='.OpenCommanderTrash-', dir=source.parent))
                target = root / source.name
                rename_new(source, target)
                self.record(operation, source, target, 'move')
        finally:
            self.finish(operation)

    def undo(self, operation_id=None):
        if not self.history:
            return
        operation = next(op for op in self.history if op['id'] == operation_id) if operation_id else self.history[-1]
        for record in list(reversed(operation['records'])):
            self.check_cancel()
            source, target = Path(record['source']), Path(record['destination'])
            if not record['reverted']:
                if record['snapshot'] is None or safe_snapshot(target) != record['snapshot']:
                    raise SafetyError(f'Undo stopped: file changed or cannot be verified.\n{target}')
                if record['kind'] == 'move':
                    if exists(source):
                        raise SafetyError(f'Undo stopped: original path is occupied.\n{source}')
                    source.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        self.move_to(target, source)
                    except CleanupError:
                        record['reverted'] = True
                        self.save()
                        raise
                else:
                    recovery = Path(tempfile.mkdtemp(prefix='.OpenCommanderUndo-', dir=target.parent)) / target.name
                    rename_new(target, recovery)
                    record['recovery'] = str(recovery)
                record['reverted'] = True
                self.save()
            if record['backup']:
                rename_new(Path(record['backup']), target)
            operation['records'].remove(record)
            self.save()  # A retry never repeats an already completed record.
        self.history.remove(operation)
        self.save()

    def make_zip(self, paths, target):
        sources = selected_roots(paths)
        target = Path(target)
        for source in sources:
            validate_target(source, target.parent)
        operation = self.begin('zip')
        operation['inputs'] = [str(source) for source in sources]
        staging = Path(tempfile.mkdtemp(prefix='.OpenCommanderTransfer-', dir=target.parent))
        try:
            payload = staging / 'payload'
            with zipfile.ZipFile(payload, 'x', zipfile.ZIP_DEFLATED) as archive:
                def add(path, name):
                    self.check_cancel()
                    if path.is_symlink():
                        raise SafetyError(f'ZIP does not follow symbolic links: {path}')
                    if path.is_dir():
                        archive.mkdir(name + '/')
                        for child in sorted(path.iterdir()):
                            add(child, name + '/' + child.name)
                    elif path.is_file():
                        with path.open('rb') as inp, archive.open(name, 'w', force_zip64=True) as out:
                            for block in iter(lambda: inp.read(1024 * 1024), b''):
                                self.check_cancel()
                                out.write(block)
                                self.bytes_done += len(block)
                                self.progress(self.bytes_done, name)
                    else:
                        raise SafetyError(f'Unsupported ZIP input: {path}')
                for source in sources:
                    add(source, source.name)
            self.publish(payload, target)
            self.record(operation, target, target, 'copy')
        finally:
            shutil.rmtree(staging, ignore_errors=True)
            self.finish(operation)

    def extract_zip(self, archive_path, directory, members=None):
        """Extract into private staging, then publish top-level entries without replacement."""
        directory = Path(directory)
        operation = self.begin('extract')
        operation['inputs'] = [str(archive_path)]
        staging = Path(tempfile.mkdtemp(prefix='.OpenCommanderTransfer-', dir=directory))
        try:
            payload = staging / 'contents'
            payload.mkdir()
            with zipfile.ZipFile(archive_path) as archive:
                entries = checked_members(archive)
                if members is not None:
                    entries = [e for e in entries if any(e.filename.rstrip('/') == m.rstrip('/')
                        or e.filename.startswith(m.rstrip('/') + '/') for m in members)]
                for entry in entries:
                    self.check_cancel()
                    target = payload.joinpath(*PurePosixPath(entry.filename).parts)
                    if entry.is_dir():
                        target.mkdir(parents=True, exist_ok=True)
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(entry) as inp, target.open('xb') as out:
                        total = 0
                        for block in iter(lambda: inp.read(1024 * 1024), b''):
                            self.check_cancel()
                            total += len(block)
                            if total > entry.file_size:
                                raise SafetyError('ZIP size mismatch')
                            out.write(block)
                            self.bytes_done += len(block)
                            self.progress(self.bytes_done, entry.filename)
                for child in sorted(payload.iterdir()):
                    target = unique_path(directory, child.name)
                    rename_new(child, target)
                    self.record(operation, target, target, 'copy')
        finally:
            shutil.rmtree(staging, ignore_errors=True)
            self.finish(operation)


def checked_members(archive):
    entries = archive.infolist()
    if len(entries) > 100_000 or sum(e.file_size for e in entries) > 4 * 1024**3:
        raise SafetyError('Archive limit: 100,000 entries / 4 GiB unpacked')
    names = set()
    for entry in entries:
        name = entry.filename
        path = PurePosixPath(name)
        if not name or path.is_absolute() or '..' in path.parts or '\\' in name or '\0' in name:
            raise SafetyError(f'Unsafe ZIP path: {name}')
        normalized = str(path)
        if normalized in ('.', '') or normalized in names:
            raise SafetyError(f'Duplicate or empty ZIP path: {name}')
        names.add(normalized)
        mode = entry.external_attr >> 16
        if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
            raise SafetyError(f'Unsupported ZIP entry: {name}')
        if entry.flag_bits & 1:
            raise SafetyError('Encrypted ZIP archives are not supported')
    return entries
