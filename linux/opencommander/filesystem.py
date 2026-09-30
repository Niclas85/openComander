from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import os
import re
import zipfile
import subprocess
import json
from .operations import checked_members


@dataclass
class Entry:
    name: str
    path: Path
    directory: bool
    size: int = 0
    modified: float = 0
    link: bool = False
    member: str | None = None
    error: str = ''


def listing(directory: Path, hidden=False):
    if remote_location(directory):
        from .integrations import invoke
        try:
            records = invoke('scan', str(directory))
        except subprocess.TimeoutExpired:
            raise OSError('Network / Cloud: Zeitüberschreitung / connection timed out (15 s)') from None
        entries = [Entry(**dict(record, path=Path(record['path']))) for record in records
                   if hidden or not record['name'].startswith('.')]
        return sorted(entries, key=lambda e: (not e.directory, e.name.casefold()))
    entries = []
    with os.scandir(directory) as stream:
        for item in stream:
            if not hidden and item.name.startswith('.'):
                continue
            try:
                info = item.stat(follow_symlinks=False)
                entries.append(Entry(item.name, Path(item.path), item.is_dir(), info.st_size,
                                     info.st_mtime, item.is_symlink()))
            except FileNotFoundError:
                continue  # An external writer removed this entry while listing.
            except PermissionError as error:
                entries.append(Entry(item.name, Path(item.path), False, error=str(error)))
    return sorted(entries, key=lambda e: (not e.directory, e.name.casefold()))


def archive_listing(path: Path, prefix=''):
    result = {}
    with zipfile.ZipFile(path) as archive:
        for item in checked_members(archive):
            if not item.filename.startswith(prefix):
                continue
            remainder = item.filename[len(prefix):].rstrip('/')
            if not remainder:
                continue
            name, separator, _ = remainder.partition('/')
            directory = bool(separator) or item.is_dir()
            result[name] = Entry(name, path, directory, item.file_size if not directory else 0,
                                 member=prefix + name + ('/' if directory else ''))
    return sorted(result.values(), key=lambda e: (not e.directory, e.name.casefold()))


def mounted_locations():
    result = []
    try:
        for line in Path('/proc/self/mountinfo').read_text().splitlines():
            fields = line.split()
            mount = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[4])
            if mount.startswith(('/media/', '/mnt/', '/run/media/')):
                path = Path(mount)
                if path not in result:
                    result.append(path)
    except (OSError, IndexError):
        pass
    return result


def cloud_locations(home=None):
    home = Path(home or Path.home())
    candidates = [home / name for name in ('Dropbox', 'OneDrive', 'Google Drive', 'Nextcloud',
                                            'iCloud', 'iCloud Drive', 'iCloudDrive')]
    # Dropbox's public installation metadata may point outside the home folder.
    try:
        info = json.loads((home / '.dropbox/info.json').read_text())
        for account in info.values():
            if isinstance(account, dict) and isinstance(account.get('path'), str):
                candidates.append(Path(account['path']))
    except (OSError, ValueError, AttributeError):
        pass
    return list(dict.fromkeys(p for p in candidates if p.is_absolute() and p.is_dir()))



def remote_location(directory):
    """Identify provider paths without probing a potentially unavailable server."""
    directory = Path(os.path.abspath(directory))
    try:
        for line in Path('/proc/self/mountinfo').read_text().splitlines():
            before, after = line.split(' - ', 1)
            filesystem = after.split()[0]
            if not filesystem.startswith(('fuse', 'nfs', 'cifs', 'smb', '9p')):
                continue
            mount = Path(re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), before.split()[4]))
            if mount == directory or mount in directory.parents:
                return True
    except (OSError, ValueError, IndexError):
        pass
    return False
