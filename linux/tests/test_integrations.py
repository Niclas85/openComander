import json
from types import SimpleNamespace
import pytest
from opencommander import integrations


@pytest.mark.parametrize('uri', ['smb://nas/share', 'sftp://alice@server/folder', 'davs://example.org/files'])
def test_network_addresses(uri):
    assert integrations.validate_uri(' ' + uri + ' ') == uri


@pytest.mark.parametrize('uri', ['file:///etc', 'https://example.org', 'smb:///share',
                                  'sftp://user:secret@server', 'smb://nas/a\nb'])
def test_invalid_or_password_addresses(uri):
    with pytest.raises(ValueError):
        integrations.validate_uri(uri)


def test_helper_uses_stdin_without_shell(monkeypatch):
    calls = []
    def run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout=json.dumps({'locations': []}))
    monkeypatch.setattr(integrations.subprocess, 'run', run)
    integrations.invoke('connect', 'smb://nas/share with spaces')
    command, arguments = calls[0]
    assert command[0] == '/usr/bin/python3'
    assert 'shell' not in arguments
    assert json.loads(arguments['input'])['id'] == 'smb://nas/share with spaces'


def test_helper_failure_reported(monkeypatch):
    monkeypatch.setattr(integrations.subprocess, 'run', lambda *a, **kw:
                        SimpleNamespace(returncode=1, stdout='{"error":"Authentication cancelled"}'))
    with pytest.raises(RuntimeError, match='Authentication cancelled'):
        integrations.invoke('connect', 'smb://nas/share')


def test_remote_listing_timeout_and_metadata(monkeypatch, tmp_path):
    import subprocess
    from opencommander import filesystem
    monkeypatch.setattr(filesystem, 'remote_location', lambda _: True)
    monkeypatch.setattr(integrations, 'invoke', lambda *args: [dict(name='cloud.txt',
                        path=str(tmp_path / 'cloud.txt'), directory=False, size=42, modified=1, link=False)])
    result = filesystem.listing(tmp_path)
    assert result[0].path == tmp_path / 'cloud.txt'
    assert result[0].size == 42
    def stalled(*args):
        raise subprocess.TimeoutExpired('helper', 15)
    monkeypatch.setattr(integrations, 'invoke', stalled)
    with pytest.raises(OSError, match='timed out'):
        filesystem.listing(tmp_path)


def test_inaccessible_remote_entry_remains_visible(monkeypatch, tmp_path):
    from opencommander import filesystem
    monkeypatch.setattr(filesystem, 'remote_location', lambda _: True)
    monkeypatch.setattr(integrations, 'invoke', lambda *args: [dict(name='restricted',
        path=str(tmp_path / 'restricted'), directory=False, error='Permission denied'),
        dict(name='readable', path=str(tmp_path / 'readable'), directory=True)])
    entries = filesystem.listing(tmp_path)
    assert len(entries) == 2
    assert entries[1].error == 'Permission denied'
