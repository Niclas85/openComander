"""Desktop integration through the host's GIO/GVFS services."""
from pathlib import Path
import json
import subprocess
from urllib.parse import urlsplit
from .desktop import host_environment


def validate_uri(value):
    value = value.strip()
    parsed = urlsplit(value)
    if parsed.scheme not in ('smb', 'sftp', 'dav', 'davs', 'ftp') or not parsed.hostname:
        raise ValueError('Adresse: smb://server/freigabe, sftp://server oder davs://server/pfad')
    if parsed.password is not None or any(ord(c) < 32 for c in value):
        raise ValueError('Passwörter bitte ausschließlich im System-Anmeldedialog eingeben.')
    return value


def invoke(action='list', identifier=''):
    result = subprocess.run(['/usr/bin/python3', str(Path(__file__).with_name('gio_bridge.py'))],
                            input=json.dumps({'action': action, 'id': identifier}),
                            text=True, capture_output=True, env=host_environment(), timeout=15 if action in ('list', 'scan', 'properties', 'directory-size') else None)
    try:
        response = json.loads(result.stdout)
    except ValueError:
        raise RuntimeError('GVFS nicht verfügbar. Benötigt: python3-gi, gir1.2-gtk-4.0, gvfs-backends und gvfs-fuse.') from None
    if result.returncode or response.get('error'):
        raise RuntimeError(response.get('error', 'GVFS operation failed'))
    return response['locations']


def open_accounts():
    subprocess.Popen(['gnome-control-center', 'online-accounts'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=host_environment())
