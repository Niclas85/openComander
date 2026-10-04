"""Verify restored QA data, remove only this run's fixtures, and leave a clean UI."""
import json
from pathlib import Path
import subprocess
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from app_store_qa_test import button, select_language

OUT = Path('parity-evidence/iphone-usability-qa/compact')
BUNDLE = 'com.github.niklaus85.OpenCommander'
DEVICE = '00008030-000E54823A91402E'
FIXTURE = 'OpenCommanderUsabilityQA'
expected = {
    'Source/ParityFile.txt': b'OpenCommander iPhone QA content\n',
    'FolderBefore/Inside.txt': b'ZIP round trip on physical iPhone\n',
    'DragMe/Drag.txt': b'Copy and move integrity\n',
    'AReverseSource/Reverse.txt': b'Reverse drag integrity\n',
    'DropHere/.qa': b'test folder\n',
    'AReverseTarget/.qa': b'test folder\n',
}


def main():
    results = json.loads((OUT / 'runner-guards.json').read_text())
    retry = OUT / 'runner-drag.json'
    if retry.exists():
        results = [r for r in results if r['suite'] != 'drag'] + json.loads(retry.read_text())
    assert [r['suite'] for r in results] == ['guards', 'edges', 'acceptance', 'drag']
    assert all(r['exit_code'] == 0 for r in results)
    assert len(json.loads((OUT / 'toolbar/checks.json').read_text())) == 24
    target = OUT / 'restored-fixture'
    target.mkdir(exist_ok=False)
    subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', DEVICE,
                    '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                    '--source', 'Documents/' + FIXTURE, '--destination', str(target)], check=True)
    actual = {str(p.relative_to(target)): p.read_bytes() for p in target.rglob('*') if p.is_file()}
    assert actual == expected, ('QA fixture not fully restored', sorted(actual))
    (OUT / 'restored-fixture-check.json').write_text(json.dumps({
        'passed': True, 'files': sorted(actual), 'exact_original_bytes': True}, indent=2) + '\n')
    options = XCUITestOptions().load_capabilities({
        'platformName': 'iOS', 'appium:automationName': 'XCUITest',
        'appium:deviceName': 'iPhone 11', 'appium:platformVersion': '26.6.1',
        'appium:udid': DEVICE, 'appium:bundleId': BUNDLE,
        'appium:noReset': True, 'appium:forceAppLaunch': True,
        'appium:webDriverAgentUrl': 'http://127.0.0.1:8153'})
    driver = webdriver.Remote('http://127.0.0.1:4753', options=options)
    try:
        driver.update_settings({'waitForIdleTimeout': .5, 'animationCoolOffTimeout': .2})
        driver.orientation = 'PORTRAIT'
        select_language(driver, 'English')
        if button(driver, 'ThemeButton').get_attribute('label') == 'Light':
            button(driver, 'ThemeButton').click()
        select_language(driver, 'Deutsch')
        for fixture in [FIXTURE, 'OpenCommanderEdgeQA']:
            driver.execute_script('mobile: deleteFolder', {'remotePath': f'@{BUNDLE}:documents/{fixture}'})
        driver.terminate_app(BUNDLE)
        driver.activate_app(BUNDLE)
        time.sleep(1)
        for pane in (1, 2):
            assert button(driver, f'Path-{pane}').get_attribute('value') == '/Documents'
        assert button(driver, 'ThemeButton').get_attribute('label') == 'Dunkel'
        driver.save_screenshot(str(OUT / 'iphone-clean-final.png'))
        (OUT / 'iphone-clean-final.xml').write_text(driver.page_source)
    finally:
        driver.quit()
    subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'files', '--device', DEVICE,
                    '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                    '--subdirectory', 'Documents', '--no-recurse',
                    '--json-output', str(OUT / 'documents-after-cleanup.json')], check=True)
    print('PASS exact six-file restoration, isolated fixture cleanup, German/light/portrait restored')


if __name__ == '__main__':
    main()
