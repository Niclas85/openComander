"""Assert physical-iPhone pane bounds after rotation and nested-path navigation.

Uses only the existing QA fixture and changes no document contents.
"""
import json
import os
from pathlib import Path
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions

from app_store_qa_test import button, select_language


def run():
    evidence = Path(os.environ['QA_EVIDENCE'])
    options = XCUITestOptions().load_capabilities({
        'platformName': 'iOS', 'appium:automationName': 'XCUITest',
        'appium:deviceName': 'iPhone 11', 'appium:udid': os.environ['IOS_UDID'],
        'appium:bundleId': 'com.github.niklaus85.OpenCommander',
        'appium:noReset': True, 'appium:forceAppLaunch': True,
        'appium:newCommandTimeout': 120,
        'appium:webDriverAgentUrl': os.environ['WDA_URL'],
    })
    driver = webdriver.Remote(os.environ['APPIUM_SERVER'], options=options)
    checks = []
    try:
        driver.orientation = 'PORTRAIT'
        select_language(driver, 'English')
        fixture = os.environ.get('QA_FIXTURE', 'OpenCommanderAppiumQA')
        for pane in (1, 2):
            field = button(driver, f'Path-{pane}')
            field.clear()
            field.send_keys(f'/Documents/{fixture}/Source\n')
            time.sleep(1)
        for orientation in ('LANDSCAPE', 'PORTRAIT', 'LANDSCAPE'):
            driver.orientation = orientation
            time.sleep(1)
            window = driver.get_window_rect()
            rects = []
            for pane in (1, 2):
                rect = button(driver, f'Pane-{pane}').rect
                assert rect['x'] >= 0 and rect['y'] >= 0, rect
                assert rect['x'] + rect['width'] <= window['width'], (rect, window)
                assert rect['y'] + rect['height'] <= window['height'], (rect, window)
                assert rect['width'] >= 300 and rect['height'] >= 200, rect
                value = button(driver, f'Path-{pane}').get_attribute('value')
                assert value == f'/Documents/{fixture}/Source', value
                assert button(driver, f'File-{pane}-ParityFile.txt').is_displayed()
                rects.append(rect)
            if orientation == 'LANDSCAPE':
                assert rects[0]['x'] + rects[0]['width'] <= rects[1]['x']
            else:
                assert rects[0]['y'] + rects[0]['height'] <= rects[1]['y']
            checks.append(f'{orientation}: both panes contained, non-overlapping, file visible, correct nested path')
            driver.save_screenshot(str(evidence / f'layout-{orientation.lower()}.png'))
        button(driver, 'Dark').click()
        driver.save_screenshot(str(evidence / 'layout-landscape-dark.png'))
        button(driver, 'Light').click()
        driver.orientation = 'PORTRAIT'
        select_language(driver, 'Deutsch')
        (evidence / 'layout-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
        print('\n'.join('PASS ' + check for check in checks), flush=True)
    except Exception:
        driver.save_screenshot(str(evidence / 'layout-failure.png'))
        (evidence / 'layout-failure.xml').write_text(driver.page_source)
        raise
    finally:
        driver.quit()


if __name__ == '__main__':
    run()
