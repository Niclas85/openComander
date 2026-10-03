from pathlib import Path
import pytest
from opencommander.desktop import folder_argument, socket_name, host_environment


def test_file_url_and_space_path(tmp_path):
    path = tmp_path / 'Meine Bilder'
    assert folder_argument(path.as_uri()) == path
    assert folder_argument(str(path)) == path
    with pytest.raises(ValueError):
        folder_argument('smb://server/share')
    assert socket_name(tmp_path) != socket_name(tmp_path / 'other')


def test_external_environment(monkeypatch):
    monkeypatch.setenv('LD_LIBRARY_PATH', '/bundle')
    monkeypatch.setenv('LD_LIBRARY_PATH_ORIG', '/system')
    monkeypatch.setenv('QT_PLUGIN_PATH', '/bundle/plugins')
    env = host_environment()
    assert env['LD_LIBRARY_PATH'] == '/system'
    assert 'QT_PLUGIN_PATH' not in env
