"""Verify exact fixture restoration before deleting only this run's test roots."""
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import unicodedata
from appium import webdriver
from appium.options.ios import XCUITestOptions
from app_store_qa_test import button, select_language

OUT = Path(os.environ['QA_EVIDENCE'])
BUNDLE = 'com.github.niklaus85.OpenCommander'
DEVICE = os.environ['IOS_UDID']

def device_files(*args):
    subprocess.run(['xcrun', 'devicectl', 'device', *args, '--device', DEVICE,
                    '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE],
                   check=True, capture_output=True)

def main():
    original = json.loads((OUT / 'fixture-originals.json').read_text())
    expected = {root: {p: base64.b64decode(v) for p,v in files.items()} for root,files in original.items()}
    expected['OpenCommanderEdgeQA'].update({
        'Guard/Folder/leaf.txt': b'Protected original\n',
        'Multi/a.txt': b'first\n', 'Multi/b.txt': b'second\n', 'MultiTarget/.qa': b'own fixture\n',
        'Files/note.txt': b'OpenCommander preview content\n', 'Files/zero.txt': b'',
        'Files/Grüße 日本語.txt': 'Grüße 日本語\n'.encode(),
        'Tree/inside/leaf.txt': b'nested leaf\n', 'Tree/.hidden': b'hidden preserved\n'})
    verified = {}
    for root,files in expected.items():
        target = OUT / 'restored-fixtures' / root
        target.mkdir(parents=True, exist_ok=False)
        device_files('copy', 'from', '--source', 'Documents/' + root, '--destination', str(target))
        actual = {unicodedata.normalize('NFC', str(p.relative_to(target))): p.read_bytes()
                  for p in target.rglob('*') if p.is_file()}
        assert actual == files, (root, 'restoration mismatch', sorted(actual), sorted(files))
        verified[root] = {'files': sorted(actual), 'exact_bytes': True, 'no_extra_files': True}
    (OUT / 'restored-fixtures.json').write_text(json.dumps(verified, indent=2) + '\n')
    d = webdriver.Remote(os.environ['APPIUM_SERVER'], options=XCUITestOptions().load_capabilities({
        'platformName': 'iOS', 'appium:automationName': 'XCUITest',
        'appium:deviceName': 'iPhone 11', 'appium:udid': DEVICE, 'appium:bundleId': BUNDLE,
        'appium:noReset': True, 'appium:forceAppLaunch': True,
        'appium:webDriverAgentUrl': os.environ['WDA_URL']}))
    try:
        d.update_settings({'waitForIdleTimeout': .5, 'animationCoolOffTimeout': .2})
        d.orientation = 'PORTRAIT'; select_language(d, 'English')
        if button(d, 'ThemeButton').get_attribute('label') == 'Light': button(d, 'ThemeButton').click()
        if button(d, 'OperationButton').get_attribute('label') != 'Copy':
            button(d, 'OperationButton').click()
        for pane in (1,2):
            field = button(d, f'Path-{pane}'); field.clear(); field.send_keys('/Documents\n')
        select_language(d, 'Deutsch')
        for root in original:
            assert root in ['OpenCommanderUsabilityQA', 'OpenCommanderEdgeQA', 'OpenCommanderDropQA']
            d.execute_script('mobile: deleteFolder', {'remotePath': f'@{BUNDLE}:documents/{root}'})
        d.terminate_app(BUNDLE); d.activate_app(BUNDLE); time.sleep(1)
        for pane in (1,2): assert button(d, f'Path-{pane}').get_attribute('value') == '/Documents'
        assert button(d, 'ThemeButton').get_attribute('label') == 'Dunkel'
        assert button(d, 'OperationButton').get_attribute('label') == 'Kopieren'
        d.save_screenshot(str(OUT / 'iphone-clean-final.png'))
        (OUT / 'iphone-clean-final.xml').write_text(d.page_source)
    finally: d.quit()
    device_files('info', 'files', '--subdirectory', 'Documents', '--no-recurse',
                 '--json-output', str(OUT / 'documents-after.json'))
    before = json.loads((OUT / 'documents-before.json').read_text())['result']['files']
    after = json.loads((OUT / 'documents-after.json').read_text())['result']['files']
    assert before == after, ('Documents listing changed outside fixtures', before, after)
    print('PASS exact restored fixture bytes; own fixtures removed; original Documents listing and German/light/portrait/Copy restored')

if __name__ == '__main__': main()
