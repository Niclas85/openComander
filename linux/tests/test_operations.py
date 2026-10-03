import errno
import os
from pathlib import Path
import stat
import zipfile

import pytest
from opencommander import operations as ops
from opencommander.operations import FileEngine, SafetyError, CleanupError, Cancelled
from opencommander.filesystem import listing, archive_listing


@pytest.fixture
def fixture(tmp_path):
    left, right = tmp_path / 'left', tmp_path / 'right'
    left.mkdir()
    right.mkdir()
    return FileEngine(tmp_path / 'state'), left, right


def write(path, value='fixture content'):
    path.write_text(value)
    return path


def test_copy_unicode_and_persistent_undo(fixture):
    engine, left, right = fixture
    source = write(left / 'Grüße 日本語.txt')
    engine.transfer([source], right)
    target = right / source.name
    assert target.read_bytes() == source.read_bytes()
    restarted = FileEngine(engine.state_dir)
    restarted.undo()
    assert not target.exists()
    assert source.exists()
    assert any(p.read_bytes() == source.read_bytes() for p in right.glob('.OpenCommanderUndo-*/*'))
    assert not restarted.history


def test_replacement_undo_restores_exact_old_inode(fixture):
    engine, left, right = fixture
    source = write(left / 'a', 'new')
    target = write(right / 'a', 'old')
    inode = target.stat().st_ino
    engine.transfer([source], right, conflict='replace')
    assert target.read_text() == 'new'
    engine.undo()
    assert target.read_text() == 'old'
    assert target.stat().st_ino == inode


def test_keep_both(fixture):
    engine, left, right = fixture
    source = write(left / 'a.txt', 'new')
    write(right / 'a.txt', 'old')
    engine.transfer([source], right)
    assert (right / 'a.txt').read_text() == 'old'
    assert (right / 'a (2).txt').read_text() == 'new'


def test_move_and_undo(fixture):
    engine, left, right = fixture
    source = write(left / 'a')
    engine.transfer([source], right, move=True)
    assert not source.exists()
    engine.undo()
    assert source.read_text() == 'fixture content'
    assert not (right / 'a').exists()


def test_move_undo_conflict_retains_both(fixture):
    engine, left, right = fixture
    source = write(left / 'a')
    engine.transfer([source], right, move=True)
    write(source, 'new file')
    with pytest.raises(SafetyError):
        engine.undo()
    assert source.read_text() == 'new file'
    assert (right / 'a').read_text() == 'fixture content'


def test_same_size_edit_even_with_original_mtime_stops_undo(fixture):
    engine, left, right = fixture
    source = write(left / 'a', 'one')
    engine.transfer([source], right)
    target = right / 'a'
    original = target.stat()
    write(target, 'two')
    os.utime(target, ns=(original.st_atime_ns, original.st_mtime_ns))
    with pytest.raises(SafetyError):
        engine.undo()
    assert target.read_text() == 'two'


def test_new_folder_child_stops_undo(fixture):
    engine, left, right = fixture
    engine.mkdir(right, 'new')
    write(right / 'new' / 'later.txt')
    with pytest.raises(SafetyError):
        engine.undo()
    assert (right / 'new' / 'later.txt').exists()


def test_undo_retry_after_partially_completed_batch(fixture):
    engine, left, right = fixture
    a, b = write(left / 'a'), write(left / 'b')
    engine.transfer([a, b], right)
    target = right / 'a'
    snapshot = target.stat()
    write(target, 'edited')
    with pytest.raises(SafetyError):
        engine.undo()
    assert not (right / 'b').exists()
    assert len(engine.history[-1]['records']) == 1
    write(target, 'fixture content')
    os.utime(target, ns=(snapshot.st_atime_ns, snapshot.st_mtime_ns))
    FileEngine(engine.state_dir).undo()
    assert not target.exists()


def test_copy_failure_never_displaces_target(fixture, monkeypatch):
    engine, left, right = fixture
    source = write(left / 'a', 'new')
    target = write(right / 'a', 'old')
    def fail(source, target):
        write(target, 'partial')
        raise OSError('injected disk full')
    monkeypatch.setattr(engine, 'copy_file', fail)
    with pytest.raises(OSError):
        engine.transfer([source], right, conflict='replace')
    assert target.read_text() == 'old'
    assert source.read_text() == 'new'
    assert not engine.history


def test_cross_volume_partial_source_delete_retains_complete_target(fixture, monkeypatch):
    engine, left, right = fixture
    source = left / 'folder'
    source.mkdir()
    write(source / 'a', 'one')
    write(source / 'b', 'two')
    real_rename = ops.rename_new
    def rename(from_path, target):
        if from_path == source:
            raise OSError(errno.EXDEV, 'injected cross-volume rename')
        real_rename(from_path, target)
    def partial_delete(path):
        (path / 'a').unlink()
        raise OSError('injected permission error')
    monkeypatch.setattr(ops, 'rename_new', rename)
    monkeypatch.setattr(ops, 'remove_tree', partial_delete)
    with pytest.raises(CleanupError):
        engine.transfer([source], right, move=True)
    assert (right / 'folder' / 'a').read_text() == 'one'
    assert (right / 'folder' / 'b').read_text() == 'two'
    assert (source / 'b').exists()


def test_atomic_publication_preserves_racing_writer(fixture, monkeypatch):
    engine, left, right = fixture
    source = write(left / 'a', 'source')
    real_copy = engine.copy_file
    def copy(source, target):
        real_copy(source, target)
        write(right / 'a', 'racing writer')
    monkeypatch.setattr(engine, 'copy_file', copy)
    with pytest.raises(FileExistsError):
        engine.transfer([source], right)
    assert (right / 'a').read_text() == 'racing writer'
    assert source.read_text() == 'source'


def test_symlinks_are_preserved_not_traversed(fixture):
    engine, left, right = fixture
    outside = write(left.parent / 'outside', 'private')
    link = left / 'link'
    link.symlink_to(outside)
    engine.transfer([link], right)
    assert (right / 'link').is_symlink()
    engine.undo()
    assert outside.read_text() == 'private'


def test_dangling_symlink_is_a_conflict(fixture):
    engine, left, right = fixture
    source = write(left / 'a')
    (right / 'a').symlink_to(right / 'missing')
    with pytest.raises(FileExistsError):
        ops.rename_new(source, right / 'a')
    assert source.exists()
    assert (right / 'a').is_symlink()


def test_nested_target_and_selected_descendants(fixture):
    engine, left, right = fixture
    folder = left / 'folder'
    folder.mkdir()
    child = write(folder / 'a')
    with pytest.raises(SafetyError):
        engine.transfer([folder], folder)
    engine.transfer([folder, child], right)
    assert len(engine.history[-1]['records']) == 1


def test_rename_new_folder_and_recoverable_remove(fixture):
    engine, left, right = fixture
    engine.mkdir(left, 'new')
    engine.rename(left / 'new', 'renamed')
    engine.trash([left / 'renamed'])
    assert not (left / 'renamed').exists()
    engine.undo()
    engine.undo()
    engine.undo()
    assert not (left / 'new').exists()


def test_zip_roundtrip_and_undo(fixture):
    engine, left, right = fixture
    folder = left / '資料'
    folder.mkdir()
    write(folder / 'Grüße.txt', 'hello')
    (folder / 'empty').mkdir()
    archive = left / 'test.zip'
    engine.make_zip([folder], archive)
    assert archive_listing(archive)[0].name == '資料'
    engine.extract_zip(archive, right)
    assert (right / '資料' / 'Grüße.txt').read_text() == 'hello'
    assert (right / '資料' / 'empty').is_dir()
    engine.undo()
    assert not (right / '資料').exists()


@pytest.mark.parametrize('name', ['../escape', '/absolute', 'a/../../escape', 'a\\b'])
def test_zip_slip_is_rejected(fixture, name):
    engine, left, right = fixture
    archive = left / 'unsafe.zip'
    with zipfile.ZipFile(archive, 'w') as out:
        out.writestr(name, 'unsafe')
    with pytest.raises(SafetyError):
        engine.extract_zip(archive, right)
    assert list(right.iterdir()) == []


def test_zip_symlink_rejected(fixture):
    engine, left, right = fixture
    archive = left / 'link.zip'
    with zipfile.ZipFile(archive, 'w') as out:
        info = zipfile.ZipInfo('link')
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        out.writestr(info, '/etc')
    with pytest.raises(SafetyError):
        engine.extract_zip(archive, right)


def test_cancel_leaves_no_partial_copy(fixture):
    engine, left, right = fixture
    source = write(left / 'a')
    engine.cancel.set()
    with pytest.raises(Cancelled):
        engine.transfer([source], right)
    assert source.exists()
    assert list(right.iterdir()) == []


def test_unreadable_history_is_retained(fixture):
    engine, left, right = fixture
    engine.history_file.write_text('broken history')
    reopened = FileEngine(engine.state_dir)
    with pytest.raises(SafetyError):
        reopened.transfer([write(left / 'a')], right)
    assert engine.history_file.read_text() == 'broken history'


def test_hidden_files_filter_and_missing_directory(fixture):
    _, left, right = fixture
    write(left / '.hidden')
    write(left / 'visible')
    assert [entry.name for entry in listing(left)] == ['visible']
    assert len(listing(left, hidden=True)) == 2
    with pytest.raises(FileNotFoundError):
        listing(right / 'missing')


def test_active_recovery_profile_cannot_be_removed(fixture):
    engine, left, right = fixture
    with pytest.raises(SafetyError):
        engine.trash([engine.state_dir])
    with pytest.raises(SafetyError):
        engine.rename(engine.state_dir, 'moved-state')
    assert engine.state_dir.is_dir()
