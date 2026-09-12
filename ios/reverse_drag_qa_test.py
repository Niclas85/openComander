"""Verify drag-and-drop from the lower iOS pane into the upper pane."""

import os
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait


def wait(driver, identifier):
    return WebDriverWait(driver, 15).until(
        lambda d: d.find_element(AppiumBy.ACCESSIBILITY_ID, identifier)
    )


def open_dir(driver, pane, name):
    identifier = f"File-{pane}-{name}"
    element = wait(driver, identifier)
    driver.execute_script("mobile: doubleTap", {"elementId": element.id})
    time.sleep(2)


options = XCUITestOptions()
options.platform_name = "iOS"
options.automation_name = "XCUITest"
options.device_name = "iPhone 15 Pro Max"
options.udid = "77AA5B73-C27E-4576-BCCD-BDA04CE116F7"
options.bundle_id = "com.github.niklaus85.OpenCommander"
options.no_reset = True
options.set_capability("appium:forceAppLaunch", True)
options.set_capability("appium:usePreinstalledWDA", True)

driver = webdriver.Remote(os.environ.get("APPIUM_SERVER", "http://127.0.0.1:4753"), options=options)
try:
    time.sleep(2)
    open_dir(driver, 1, "OpenCommanderParity")
    open_dir(driver, 2, "OpenCommanderParity")
    if os.environ.get("MOVE_MODE") == "1":
        if wait(driver, "OperationButton").get_attribute("label") != "Move":
            wait(driver, "OperationButton").click()
    source_name = os.environ.get("DRAG_SOURCE", "AReverseSource")
    target_name = os.environ.get("DRAG_TARGET", "AReverseTarget")
    source = wait(driver, f"File-2-{source_name}")
    target = wait(driver, f"File-1-{target_name}")
    driver.execute_script("mobile: dragFromToForDuration", {
        "duration": 1.5,
        "fromX": source.rect["x"] + source.rect["width"] / 2,
        "fromY": source.rect["y"] + source.rect["height"] / 2,
        "toX": target.rect["x"] + target.rect["width"] / 2,
        "toY": target.rect["y"] + target.rect["height"] / 2,
    })
    time.sleep(2)
    if os.environ.get("UNDO_AFTER") == "1":
        wait(driver, "UndoButton").click()
        time.sleep(2)
finally:
    try:
        driver.quit()
    except Exception:
        pass
