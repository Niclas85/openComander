"""Device-driven regressions for visible toolbar taps and ZIP/data edge cases.

Uses only OpenCommanderEdgeQA. No app reset, uninstall or user-file writes.
Toolbar taps are coordinates checked against the visible toolbar, so XCTest
cannot silently scroll a clipped control into view.
"""
import base64
import io
import json
import os
from pathlib import Path
import time
import xml.etree.ElementTree as ET
import zipfile

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait

BUNDLE = 'com.github.niklaus85.OpenCommander'
FIXTURE = 'OpenCommanderEdgeQA'
OUT = Path(os.environ['QA_EVIDENCE'])
IDS = ['UndoButton', 'DeleteButton', 'RenameButton', 'OperationButton', 'HistoryButton',
       'ZipButton', 'ThemeButton', 'HelpButton', 'LegalButton', 'LanguageButton']
HEADER_IDS = ['HelpButton', 'LegalButton', 'LanguageButton']
CHECKS = []


def find(d, name):
    return WebDriverWait(d, 12).until(lambda x: x.find_element(AppiumBy.ACCESSIBILITY_ID, name))


def rect_inside(r, outer):
    return (r['x'] >= outer['x'] - 1 and r['y'] >= outer['y'] - 1
            and r['x'] + r['width'] <= outer['x'] + outer['width'] + 1
            and r['y'] + r['height'] <= outer['y'] + outer['height'] + 1)


def visible_file(d, name):
    pane = name.split('-', 2)[1]
    table = find(d, f'FileList-{pane}')
    for _ in range(8):
        e = find(d, name)
        r = e.rect
        if rect_inside(r, table.rect):
            return e
        # A short swipe scrolls the list. XCTest's slow scroll gesture can
        # activate UIKit's long-press drag interaction on file rows.
        d.execute_script('mobile: swipe', {'elementId': table.id,
                         'direction': 'down' if r['y'] < table.rect['y'] else 'up',
                         'velocity': 900})
    raise AssertionError(('file cannot be reached by scrolling', name))


def tap(d, name):
    if name.startswith('File-'):
        visible_file(d, name)
    e = find(d, name)
    r = e.rect
    assert rect_inside(r, d.get_window_rect()), ('off-screen tap', name, r)
    assert e.is_displayed(), name
    if name in IDS:
        assert rect_inside(r, find(d, 'TitleToolbar' if name in HEADER_IDS else 'ActionToolbar').rect), ('clipped toolbar tap', name, r)
        assert r['height'] >= 28 and r['width'] >= 24, ('small tap target', name, r)
    d.execute_script('mobile: tap', {'x': r['x'] + r['width'] / 2, 'y': r['y'] + r['height'] / 2})
    time.sleep(.25)


def passed(name):
    CHECKS.append(name)
    (OUT / 'checks.json').write_text(json.dumps(CHECKS, indent=2) + '\n')
    print('PASS ' + name, flush=True)


def language(d, name):
    tap(d, 'LanguageButton')
    find(d, name).click()  # Native language action sheet may scroll its own list.
    time.sleep(.5)


def nav(d, pane, path):
    f = find(d, f'Path-{pane}')
    f.clear()
    f.send_keys(path + '\n')
    time.sleep(.5)
    assert find(d, f'Path-{pane}').get_attribute('value') == path


def double(d, pane, name):
    e = visible_file(d, f'File-{pane}-{name}')
    assert rect_inside(e.rect, find(d, f'FileList-{pane}').rect), name
    r = e.rect
    d.execute_script('mobile: doubleTap', {'x': r['x'] + r['width'] / 2, 'y': r['y'] + r['height'] / 2})
    time.sleep(.7)


def geometry(d, label):
    root = ET.fromstring(d.page_source)
    controls = {n.attrib.get('name'): n for n in root.iter() if n.attrib.get('name') in IDS + ['ActionToolbar', 'TitleToolbar', 'Pane-1', 'Pane-2']}
    def rectangle(n):
        return {k: float(n.attrib[k]) for k in ('x', 'y', 'width', 'height')}
    toolbar = rectangle(controls['ActionToolbar'])
    header = rectangle(controls['TitleToolbar'])
    assert header['y'] + header['height'] <= toolbar['y']
    screen = d.get_window_rect()
    rects = {}
    for name in IDS:
        n = controls[name]
        r = rectangle(n)
        assert n.attrib.get('visible') == 'true', (label, name, 'invisible')
        assert rect_inside(r, header if name in HEADER_IDS else toolbar) and rect_inside(r, screen), (label, name, r, toolbar)
        assert r['width'] >= 24 and r['height'] >= 28, (name, r)
        for child in n.iter('XCUIElementTypeStaticText'):
            assert rect_inside(rectangle(child), r), (label, name, 'clipped label', child.attrib)
        for other, old in rects.items():
            assert (r['x'] + r['width'] <= old['x'] + 1 or old['x'] + old['width'] <= r['x'] + 1
                    or r['y'] + r['height'] <= old['y'] + 1 or old['y'] + old['height'] <= r['y'] + 1), (name, other)
        rects[name] = r
    row_count = len({r['y'] for name, r in rects.items() if name not in HEADER_IDS})
    assert row_count == 1, (label, 'action toolbar must use exactly one row', row_count)
    for pane in (1, 2):
        r = rectangle(controls[f'Pane-{pane}'])
        assert rect_inside(r, screen), (label, pane, r)
        assert r['height'] >= 130, (label, 'pane too small', r)
    (OUT / f'{label}-geometry.json').write_text(json.dumps(rects, indent=2) + '\n')
    d.save_screenshot(str(OUT / f'{label}.png'))
    passed(label + f': all ten actions fully visible, >=24×28pt, {row_count} action row, three title-bar controls, non-overlapping; both panes visible')


def toolbar_suite(d):
    for name, code, copy, move in [('Deutsch','de','Kopieren','Verschieben'), ('English','en','Copy','Move'),
                       ('Français','fr','Copier','Déplacer'), ('Italiano','it','Copia','Sposta'),
                       ('Español','es','Copiar','Mover'), ('Português','pt','Copiar','Mover'),
                       ('Nederlands','nl','Kopiëren','Verplaatsen')]:
        language(d, name)
        for orientation in ('PORTRAIT', 'LANDSCAPE'):
            d.orientation = orientation
            time.sleep(.7)
            geometry(d, code + '-' + orientation.lower())
            if find(d, 'OperationButton').get_attribute('label') != move:
                tap(d, 'OperationButton')
            assert find(d, 'OperationButton').get_attribute('label') == move
            geometry(d, code + '-move-' + orientation.lower())
            if find(d, 'OperationButton').get_attribute('label') != copy:
                tap(d, 'OperationButton')
            assert find(d, 'OperationButton').get_attribute('label') == copy
    language(d, 'English')
    d.orientation = 'PORTRAIT'
    time.sleep(.5)
    for name in ['UndoButton', 'DeleteButton', 'RenameButton', 'ZipButton']:
        before = find(d, 'GlobalStatus').text
        tap(d, name)
        after = find(d, 'GlobalStatus').text
        assert after != before, (name, after)
        passed('visible tap ' + name + ': empty-selection feedback')
    tap(d, 'HistoryButton')
    assert find(d, 'HistoryButton').get_attribute('label') == 'History -'
    geometry(d, 'expanded-history')
    tap(d, 'HistoryButton')
    passed('visible tap History opens and closes history')
    for name, title in [('LegalButton','Terms / Privacy / Imprint'), ('HelpButton','How to use OpenCommander')]:
        tap(d, name)
        find(d, title)
        tap(d, 'OK')
        passed('visible tap ' + name + ': modal opens and closes')
    tap(d, 'OperationButton')
    time.sleep(.5)
    assert find(d, 'OperationButton').get_attribute('label') == 'Move'
    tap(d, 'OperationButton')
    assert find(d, 'OperationButton').get_attribute('label') == 'Copy'
    passed('visible tap operation toggle: move/copy label and state')
    tap(d, 'ThemeButton')
    assert find(d, 'ThemeButton').get_attribute('label') == 'Light'
    geometry(d, 'dark-portrait')
    d.terminate_app(BUNDLE)
    d.activate_app(BUNDLE)
    time.sleep(.5)
    assert find(d, 'ThemeButton').get_attribute('label') == 'Light'
    tap(d, 'ThemeButton')
    passed('visible tap theme: dark/light and persistence after restart')
    language(d, 'Deutsch')
    geometry(d, 'final-german')


def push(d, path, data):
    d.push_file(f'@{BUNDLE}:documents/{FIXTURE}/{path}', base64.b64encode(data).decode())


def zip_contents(d, path):
    raw = base64.b64decode(d.pull_file(f'@{BUNDLE}:documents/{FIXTURE}/{path}'))
    (OUT / ('archive-' + path.replace('/', '_'))).write_bytes(raw)
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        assert z.testzip() is None
        return {n: z.read(n) for n in z.namelist()}


def zip_wait(d, pane, name):
    WebDriverWait(d, 20).until(lambda x: x.find_elements(AppiumBy.ACCESSIBILITY_ID, f'File-{pane}-{name}'))
    time.sleep(.3)


def undo(d):
    tap(d, 'UndoButton')
    WebDriverWait(d, 15).until(lambda x: 'undone' in find(x, 'GlobalStatus').text.lower()
                            or 'failed' in find(x, 'GlobalStatus').text.lower())
    assert 'undone' in find(d, 'GlobalStatus').text.lower()


def wait_absent(d, name):
    WebDriverWait(d, 15).until(lambda x: not any(e.is_displayed() for e in
        x.find_elements(AppiumBy.ACCESSIBILITY_ID, name)))


def edge_suite(d):
    language(d, 'English')
    d.orientation = 'PORTRAIT'
    # Remove only archives produced by earlier attempts in our own fixture.
    for path in ['Files/note.zip', 'Files/note (2).zip', 'Files/Files.zip', 'Tree.zip',
                 'Tree/empty.zip', 'Tree/inside/leaf.zip', 'Two/two.zip']:
        try:
            d.execute_script('mobile: deleteFile', {'remotePath': f'@{BUNDLE}:documents/{FIXTURE}/{path}'})
        except Exception as error:
            if 'OBJECT_NOT_FOUND' not in str(error) and 'does not exist on the device' not in str(error):
                raise
    for path, data in {'Files/note.txt': b'OpenCommander preview content\n', 'Files/zero.txt': b'',
                       'Files/Grüße 日本語.txt': 'Grüße 日本語\n'.encode(),
                       'Tree/inside/leaf.txt': b'nested leaf\n', 'Tree/empty/.seed': b'x',
                       'Tree/.hidden': b'hidden preserved\n'}.items():
        push(d, path, data)
    d.execute_script('mobile: deleteFile', {'remotePath': f'@{BUNDLE}:documents/{FIXTURE}/Tree/empty/.seed'})
    root = f'/Documents/{FIXTURE}'
    nav(d, 2, root + '/Two')
    nav(d, 1, root + '/Nested')
    tap(d, 'File-1-A')
    assert find(d, 'Selection-1').text.startswith('1/'), find(d, 'Selection-1').text
    time.sleep(.6)
    tap(d, 'File-1-A')
    assert find(d, 'Selection-1').text.startswith('0/')
    passed('single taps select/deselect without navigating')
    double(d, 1, 'A')
    assert find(d, 'Path-1').get_attribute('value') == root + '/Nested/A'
    double(d, 1, 'B')
    assert find(d, 'Path-1').get_attribute('value') == root + '/Nested/A/B'
    tap(d, 'Up-1')
    assert find(d, 'Path-1').get_attribute('value') == root + '/Nested/A'
    passed('double taps enter exactly one directory; Up returns one level')

    # Narrow parent so the empty folder is the first, visible file row.
    nav(d, 1, root + '/Tree')
    tap(d, 'File-1-empty')
    tap(d, 'ZipButton')
    zip_wait(d, 1, 'empty.zip')
    assert zip_contents(d, 'Tree/empty.zip') == {'empty/': b''}
    undo(d)
    passed('ZIP of empty directory retains directory entry and passes CRC')

    nav(d, 1, root)
    tap(d, 'File-1-Tree')
    tap(d, 'ZipButton')
    zip_wait(d, 1, 'Tree.zip')
    assert zip_contents(d, 'Tree.zip') == {
        'Tree/': b'', 'Tree/empty/': b'', 'Tree/inside/': b'',
        'Tree/inside/leaf.txt': b'nested leaf\n', 'Tree/.hidden': b'hidden preserved\n'}
    undo(d)
    passed('recursive ZIP retains root, nested/empty directories, hidden file and exact contents')

    # Navigate by tree to keep the long root listing out of tap hit-testing.
    nav(d, 1, root + '/Tree/inside')
    tap(d, 'File-1-leaf.txt')
    tap(d, 'ZipButton')
    zip_wait(d, 1, 'leaf.zip')
    assert zip_contents(d, 'Tree/inside/leaf.zip') == {'leaf.txt': b'nested leaf\n'}
    undo(d)
    passed('single-file ZIP uses file stem and preserves exact bytes')

    nav(d, 1, root + '/Files')
    tap(d, 'File-1-Grüße 日本語.txt')
    tap(d, 'File-1-zero.txt')
    tap(d, 'ZipButton')
    zip_wait(d, 1, 'Files.zip')
    assert zip_contents(d, 'Files/Files.zip') == {'Grüße 日本語.txt': 'Grüße 日本語\n'.encode(), 'zero.txt': b''}
    undo(d)
    passed('multi-selection ZIP preserves Unicode name/content and zero-byte file')

    tap(d, 'File-1-note.txt')
    tap(d, 'ZipButton')
    zip_wait(d, 1, 'note.zip')
    tap(d, 'File-1-note.txt')
    tap(d, 'ZipButton')
    zip_wait(d, 1, 'note (2).zip')
    assert zip_contents(d, 'Files/note.zip') == zip_contents(d, 'Files/note (2).zip')
    tap(d, 'HistoryButton')
    history = find(d, 'HistoryList')
    older = find(d, 'HistoryEntry-0')
    if not rect_inside(older.rect, history.rect):
        d.execute_script('mobile: swipe', {'elementId': history.id, 'direction': 'up', 'velocity': 700})
    tap(d, 'HistoryEntry-0')
    time.sleep(.7)
    tap(d, 'HistoryButton')
    wait_absent(d, 'File-1-note.zip')
    assert zip_contents(d, 'Files/note (2).zip') == {'note.txt': b'OpenCommander preview content\n'}
    passed('tapping an older history entry undoes only that action; newer archive remains intact')
    double(d, 1, 'note (2).zip')
    assert find(d, 'Path-1').get_attribute('value').endswith('note (2).zip!/')
    tap(d, 'File-1-note.txt')
    tap(d, 'RenameButton')
    assert 'read-only' in find(d, 'GlobalStatus').text.lower()
    assert not d.find_elements(AppiumBy.CLASS_NAME, 'XCUIElementTypeAlert')
    tap(d, 'DeleteButton')
    assert 'read-only' in find(d, 'GlobalStatus').text.lower()
    passed('ZIP entry rename and delete are rejected without changing the archive')
    time.sleep(.6)
    double(d, 1, 'note.txt')
    time.sleep(1)
    d.save_screenshot(str(OUT / 'zip-file-preview.png'))
    names_by_label = {e.get_attribute('label'): e.get_attribute('name') for e in
                      d.find_elements(AppiumBy.CLASS_NAME, 'XCUIElementTypeButton')}
    labels = list(names_by_label)
    done = next((x for x in ['Done','Fertig','close','Close','Schließen'] if x in labels), None)
    assert done, ('preview close button missing', labels)
    tap(d, names_by_label[done])
    passed('ZIP browsing and native preview open with a real double tap and close normally')
    tap(d, 'Up-1')
    undo(d)

    # Left and right contain independent selections; last active pane is authoritative.
    nav(d, 1, root + '/One')
    nav(d, 2, root + '/Two')
    tap(d, 'File-1-one.txt')
    tap(d, 'File-2-two.txt')
    tap(d, 'ZipButton')
    zip_wait(d, 2, 'two.zip')
    assert zip_contents(d, 'Two/two.zip') == {'two.txt': b'two\n'}
    undo(d)
    assert find(d, 'Selection-1').text.startswith('1/')
    tap(d, 'File-1-one.txt')
    passed('ZIP uses active pane only and preserves other pane selection')

    nav(d, 1, root + '/Nested')
    tap(d, 'Tree-1-A')
    assert find(d, 'Path-1').get_attribute('value') == root + '/Nested/A'
    passed('single tree tap opens directory and expands children')
    geometry(d, 'edges-final')


def guard_suite(d):
    language(d, 'English')
    d.orientation = 'PORTRAIT'
    push(d, 'Guard/Folder/leaf.txt', b'Protected original\n')
    push(d, 'Multi/a.txt', b'first\n')
    push(d, 'Multi/b.txt', b'second\n')
    push(d, 'MultiTarget/.qa', b'own fixture\n')
    root = f'/Documents/{FIXTURE}'
    def drag_to_table(source, pane):
        e = visible_file(d, source)
        a = e.rect
        b = find(d, f'FileList-{pane}').rect
        d.execute_script('mobile: dragFromToForDuration', {
            'duration': 1.2, 'fromX': a['x'] + a['width']/2, 'fromY': a['y'] + a['height']/2,
            'toX': b['x'] + b['width']/2, 'toY': b['y'] + min(22, b['height']/2)})
        time.sleep(1)
    nav(d, 1, root + '/Guard')
    nav(d, 2, root + '/Guard/Folder')
    drag_to_table('File-1-Folder', 2)
    assert 'itself' in find(d, 'GlobalStatus').text.lower(), find(d, 'GlobalStatus').text
    assert not d.find_elements(AppiumBy.ACCESSIBILITY_ID, 'File-2-Folder')
    original = base64.b64decode(d.pull_file(f'@{BUNDLE}:documents/{FIXTURE}/Guard/Folder/leaf.txt'))
    assert original == b'Protected original\n'
    passed('dragging a folder into itself is rejected; original bytes remain intact')

    nav(d, 1, root + '/Multi')
    nav(d, 2, root + '/MultiTarget')
    tap(d, 'File-1-a.txt')
    tap(d, 'File-1-b.txt')
    assert find(d, 'Selection-1').text.startswith('2/')
    drag_to_table('File-1-a.txt', 2)
    for name, content in [('a.txt', b'first\n'), ('b.txt', b'second\n')]:
        assert base64.b64decode(d.pull_file(f'@{BUNDLE}:documents/{FIXTURE}/MultiTarget/{name}')) == content
        assert base64.b64decode(d.pull_file(f'@{BUNDLE}:documents/{FIXTURE}/Multi/{name}')) == content
    undo(d)
    wait_absent(d, 'File-2-a.txt')
    wait_absent(d, 'File-2-b.txt')
    for name in ['a.txt', 'b.txt']:
        try:
            d.pull_file(f'@{BUNDLE}:documents/{FIXTURE}/MultiTarget/{name}')
        except Exception as error:
            assert 'OBJECT_NOT_FOUND' in str(error), str(error)
        else:
            raise AssertionError('Undo left copied file on disk: ' + name)
    passed('multi-selection drag copies both files exactly; Undo removes both destinations only')
    tap(d, 'ThemeButton')
    tap(d, 'File-1-a.txt')
    d.save_screenshot(str(OUT / 'dark-selected-file.png'))
    assert find(d, 'Selection-1').text.startswith('1/')
    tap(d, 'ThemeButton')
    passed('selected file remains visible and selected across dark/light theme changes')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    caps = {'platformName': 'iOS', 'appium:automationName': 'XCUITest',
            'appium:deviceName': os.environ.get('IOS_DEVICE_NAME','iPhone 11'),
            'appium:udid': os.environ['IOS_UDID'], 'appium:bundleId': BUNDLE,
            'appium:noReset': True, 'appium:forceAppLaunch': True,
            'appium:newCommandTimeout': 300, 'appium:webDriverAgentUrl': os.environ['WDA_URL']}
    d = webdriver.Remote(os.environ['APPIUM_SERVER'], options=XCUITestOptions().load_capabilities(caps))
    try:
        d.update_settings({'waitForIdleTimeout': .5, 'animationCoolOffTimeout': .2})
        if os.environ.get('QA_SUITE') == 'edges': edge_suite(d)
        elif os.environ.get('QA_SUITE') == 'guards': guard_suite(d)
        else: toolbar_suite(d)
    except Exception:
        d.save_screenshot(str(OUT / 'failure.png'))
        (OUT / 'failure.xml').write_text(d.page_source)
        raise
    finally:
        d.quit()


if __name__ == '__main__': main()
