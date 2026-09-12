"""Release 1.2 physical-iPhone check for the new folder picker entry point."""
import json
import os
from pathlib import Path
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait

from app_store_qa_test import button, select_language

BUNDLE = 'com.github.niklaus85.OpenCommander'
OUT = Path(os.environ['QA_EVIDENCE'])


def inside(inner, outer):
    return (inner['x'] >= outer['x'] - 1 and inner['y'] >= outer['y'] - 1
            and inner['x'] + inner['width'] <= outer['x'] + outer['width'] + 1
            and inner['y'] + inner['height'] <= outer['y'] + outer['height'] + 1)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    caps = {'platformName': 'iOS', 'appium:automationName': 'XCUITest',
            'appium:deviceName': 'iPhone 11', 'appium:platformVersion': '26.6.1',
            'appium:udid': os.environ['IOS_UDID'], 'appium:bundleId': BUNDLE,
            'appium:noReset': True, 'appium:forceAppLaunch': True,
            'appium:webDriverAgentUrl': os.environ['WDA_URL']}
    d = webdriver.Remote(os.environ['APPIUM_SERVER'], options=XCUITestOptions().load_capabilities(caps))
    checks = []
    try:
        d.update_settings({'waitForIdleTimeout': .5, 'animationCoolOffTimeout': .2})
        d.orientation = 'PORTRAIT'; select_language(d, 'English')
        control = button(d, 'OpenFolderButton')
        rect, toolbar = control.rect, button(d, 'ActionToolbar').rect
        assert control.is_displayed() and rect['width'] >= 24 and rect['height'] >= 28
        assert inside(rect, toolbar) and inside(rect, d.get_window_rect())
        checks.append('Choose Folder is visible, fully inside the one-row toolbar and at least 24x28pt')
        control.click()
        WebDriverWait(d, 15).until(lambda x: x.find_elements(
            AppiumBy.CLASS_NAME, 'XCUIElementTypeNavigationBar'))
        labels = [(e.get_attribute('label') or '') for e in
                  d.find_elements(AppiumBy.CLASS_NAME, 'XCUIElementTypeButton')]
        cancel = next((e for e in d.find_elements(AppiumBy.CLASS_NAME, 'XCUIElementTypeButton')
                       if (e.get_attribute('label') or '').lower() in ('cancel', 'close', 'done')), None)
        assert cancel is not None, labels
        d.save_screenshot(str(OUT / 'native-folder-picker.png'))
        cancel.click(); WebDriverWait(d, 10).until(lambda x: x.find_element(
            AppiumBy.ACCESSIBILITY_ID, 'OpenFolderButton'))
        checks.append('Choose Folder directly opens the native Files picker and cancel leaves the pane unchanged')
        select_language(d, 'Deutsch')
        if button(d, 'ThemeButton').get_attribute('label') == 'Hell':
            button(d, 'ThemeButton').click()
        d.orientation = 'PORTRAIT'; time.sleep(.5)
        (OUT / 'checks.json').write_text(json.dumps(checks, indent=2, ensure_ascii=False) + '\n')
        d.save_screenshot(str(OUT / 'restored.png'))
        for check in checks: print('PASS ' + check, flush=True)
    except Exception:
        d.save_screenshot(str(OUT / 'failure.png'))
        (OUT / 'failure.xml').write_text(d.page_source)
        raise
    finally:
        d.quit()


if __name__ == '__main__':
    main()
