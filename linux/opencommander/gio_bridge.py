"""Host Python helper: use the desktop's GVFS and authentication dialogs.

Only public mount metadata crosses stdout; credentials stay in Gtk/GVFS.
"""
import json
import os
import sys
import time
import gi
from gi.repository import Gio, GLib


def identity(volume):
    root = volume.get_activation_root()
    return volume.get_uuid() or volume.get_identifier('unix-device') or (root.get_uri() if root else 'name:' + volume.get_name())


def locations(monitor):
    result = []
    for mount in monitor.get_mounts():
        if mount.is_shadowed():
            continue
        root = mount.get_root()
        drive = mount.get_drive()
        result.append(dict(id=root.get_uri(), name=mount.get_name(), path=root.get_path(),
                           mounted=True, eject=mount.can_eject(), unmount=mount.can_unmount(),
                           kind='USB' if drive and drive.is_removable() else
                           'Network / Cloud' if root.get_uri().split(':')[0] != 'file' else 'Drive / Cloud'))
    for volume in monitor.get_volumes():
        if not volume.get_mount() and volume.can_mount():
            result.append(dict(id=identity(volume), name=volume.get_name(), path=None,
                               mounted=False, eject=False, unmount=False, kind='Drive'))
    return result


def provider_file(path, monitor):
    """Resolve a GVFS FUSE path back to its SMB/cloud URI before querying."""
    path = os.path.abspath(path)
    candidates = []
    for mount in monitor.get_mounts():
        root = mount.get_root()
        local = root.get_path()
        if local and (path == local or path.startswith(local.rstrip('/') + '/')):
            candidates.append((len(local), root, os.path.relpath(path, local)))
    if candidates:
        _, root, relative = max(candidates, key=lambda item: item[0])
        return root if relative == '.' else root.resolve_relative_path(relative)
    return Gio.File.new_for_path(path)


def properties(path, monitor):
    file = provider_file(path, monitor)
    info = file.query_info('standard::*,time::*,owner::*,unix::mode,access::*',
                           Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, None)
    def attr(key):
        if not info.has_attribute(key):
            return None
        kind = info.get_attribute_type(key)
        if kind == Gio.FileAttributeType.BOOLEAN:
            return info.get_attribute_boolean(key)
        if kind == Gio.FileAttributeType.UINT64:
            return info.get_attribute_uint64(key)
        if kind == Gio.FileAttributeType.UINT32:
            return info.get_attribute_uint32(key)
        return info.get_attribute_as_string(key)
    result = dict(path=path, uri=file.get_uri(), name=info.get_display_name(),
                  directory=info.get_file_type() == Gio.FileType.DIRECTORY,
                  type=info.get_file_type().value_nick, size=attr('standard::size'),
                  modified=attr('time::modified'), created=attr('time::created'),
                  accessed=attr('time::access'), owner=attr('owner::user'), group=attr('owner::group'),
                  mode=attr('unix::mode'), read=attr('access::can-read'), write=attr('access::can-write'),
                  content_type=attr('standard::content-type'), link=attr('standard::symlink-target'))
    try:
        fs = file.query_filesystem_info('filesystem::type,filesystem::readonly,filesystem::free,filesystem::size', None)
        result['filesystem'] = fs.get_attribute_string('filesystem::type')
        for key in ('free', 'size'):
            result['filesystem_' + key] = fs.get_attribute_uint64('filesystem::' + key) if fs.has_attribute('filesystem::' + key) else None
        result['readonly'] = fs.get_attribute_boolean('filesystem::readonly') if fs.has_attribute('filesystem::readonly') else None
    except GLib.Error:
        pass
    return result


def directory_size(path, monitor):
    root = provider_file(path, monitor)
    info = root.query_info('standard::type,standard::is-symlink', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, None)
    if info.get_file_type() != Gio.FileType.DIRECTORY or info.get_is_symlink():
        raise ValueError('Not a directory, or a symbolic link: ' + path)
    queue = [root]
    result = dict(bytes=0, files=0, directories=0, errors=0, complete=True)
    deadline = time.monotonic() + 10
    count = 0
    while queue:
        directory = queue.pop()
        try:
            stream = directory.enumerate_children('standard::name,standard::type,standard::size,standard::is-symlink',
                                                 Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, None)
            try:
                while True:
                    if time.monotonic() > deadline or count >= 100000:
                        result['complete'] = False
                        return result
                    info = stream.next_file(None)
                    if info is None:
                        break
                    count += 1
                    if info.get_file_type() == Gio.FileType.DIRECTORY and not info.get_is_symlink():
                        result['directories'] += 1
                        queue.append(directory.get_child(info.get_name()))
                    else:
                        result['files'] += 1
                        if info.has_attribute('standard::size'):
                            result['bytes'] += info.get_size()
                        else:
                            result['errors'] += 1
            finally:
                stream.close(None)
        except GLib.Error:
            result['errors'] += 1
    result['complete'] = not result['errors']
    return result


def main():
    request = json.load(sys.stdin)
    action = request['action']
    if action == 'scan':
        result = []
        with os.scandir(request['id']) as stream:
            for item in stream:
                try:
                    info = item.stat(follow_symlinks=False)
                    result.append(dict(name=item.name, path=item.path, directory=item.is_dir(),
                                       size=info.st_size, modified=info.st_mtime, link=item.is_symlink()))
                except FileNotFoundError:
                    continue
                except PermissionError as error:
                    result.append(dict(name=item.name, path=item.path, directory=False,
                                       size=0, modified=0, link=False, error=str(error)))
        return result
    monitor = Gio.VolumeMonitor.get()
    if action == 'directory-size':
        return directory_size(request['id'], monitor)
    if action == 'properties':
        return properties(request['id'], monitor)
    if action == 'list':
        return locations(monitor)
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gtk
    Gtk.init()
    if action == 'open-with':
        file = Gio.File.new_for_path(request['id'])
        dialog = Gtk.AppChooserDialog.new(None, Gtk.DialogFlags.MODAL, file)
        dialog.get_widget().set_show_all(True)
        chooser_loop = GLib.MainLoop()
        result = {'launched': False}
        def selected(chooser, response):
            if response == Gtk.ResponseType.OK:
                app = chooser.get_app_info()
                try:
                    if app is None:
                        raise RuntimeError('No application selected')
                    if not app.launch([file], None):
                        raise RuntimeError('Application could not be started')
                    result['launched'] = True
                except Exception as error:
                    result['error'] = str(error)
            chooser.destroy()
            chooser_loop.quit()
        dialog.connect('response', selected)
        dialog.present()
        chooser_loop.run()
        if result.get('error'):
            raise RuntimeError(result['error'])
        return result
    operation = Gtk.MountOperation.new(None)
    loop = GLib.MainLoop()
    errors = []

    def done(source, result, finish):
        try:
            getattr(source, finish)(result)
        except GLib.Error as error:
            if not error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED):
                errors.append(str(error))
        loop.quit()

    key = request['id']
    if action == 'connect':
        Gio.File.new_for_uri(key).mount_enclosing_volume(
            Gio.MountMountFlags.NONE, operation, None, done, 'mount_enclosing_volume_finish')
    elif action == 'mount':
        volume = next((v for v in monitor.get_volumes() if identity(v) == key), None)
        if volume is None:
            raise RuntimeError('Volume no longer available')
        volume.mount(Gio.MountMountFlags.NONE, operation, None, done, 'mount_finish')
    elif action in ('eject', 'unmount'):
        mount = next((m for m in monitor.get_mounts() if m.get_root().get_uri() == key), None)
        if mount is None:
            raise RuntimeError('Mount no longer available')
        method = 'eject_with_operation' if action == 'eject' else 'unmount_with_operation'
        getattr(mount, method)(Gio.MountUnmountFlags.NONE, operation, None, done, method + '_finish')
    else:
        raise ValueError('Unknown action')
    loop.run()
    if errors:
        raise RuntimeError(errors[0])
    return locations(monitor)


if __name__ == '__main__':
    try:
        print(json.dumps({'locations': main()}))
    except Exception as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
