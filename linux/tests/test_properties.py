from pathlib import Path
import json
import zipfile
from opencommander.filesystem import Entry, cloud_locations
from opencommander import properties_ui


def test_unknown_values_not_false_or_zero_and_directory_size():
    text = properties_ui.format_properties(dict(name='NAS', path='/nas', directory=True, size=0))
    assert 'Ordnerinhalt nicht rekursiv berechnet' in text
    assert 'Schreiben erlaubt: Nicht vom Dateisystem gemeldet' in text
    assert '0 Bytes' not in text
    assert '1970' not in text


def test_fresh_properties_not_cached_size(monkeypatch, tmp_path):
    entry = Entry('a.txt', tmp_path / 'a.txt', False, size=1)
    calls = []
    def invoke(action, path):
        calls.append((action, path))
        return dict(name='a.txt', size=999)
    monkeypatch.setattr(properties_ui, 'invoke', invoke)
    assert properties_ui.properties(entry)['size'] == 999
    assert calls == [('properties', str(entry.path))]


def test_local_properties_without_gvfs(monkeypatch, tmp_path):
    path = tmp_path / 'a.txt'
    path.write_text('abc')
    def unavailable(*args):
        raise RuntimeError('No gi')
    monkeypatch.setattr(properties_ui, 'invoke', unavailable)
    result = properties_ui.properties(Entry(path.name, path, False, size=99))
    assert result['size'] == 3
    assert result['created'] is None


def test_archive_properties_use_member_not_container(tmp_path):
    path = tmp_path / 'test.zip'
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('folder/a.txt', 'hello')
    result = properties_ui.properties(Entry('a.txt', path, False, member='folder/a.txt'))
    assert result['size'] == 5
    assert result['path'].endswith('!/folder/a.txt')


def test_cloud_locations_include_icloud_and_custom_dropbox(tmp_path):
    for name in ('Google Drive', 'OneDrive', 'iCloud Drive', 'Company Dropbox'):
        (tmp_path / name).mkdir()
    (tmp_path / '.dropbox').mkdir()
    (tmp_path / '.dropbox/info.json').write_text(json.dumps({'personal': {'path': str(tmp_path / 'Company Dropbox')}}))
    locations = cloud_locations(tmp_path)
    assert set(locations) == {tmp_path / name for name in ('Google Drive', 'OneDrive', 'iCloud Drive', 'Company Dropbox')}


def test_invalid_provider_timestamp_is_unknown():
    text = properties_ui.format_properties(dict(name='NAS', path='/nas', modified=2**64-1))
    assert 'Geändert: Nicht vom Dateisystem gemeldet' in text
