"""Cross-platform OpenCommander parity smoke/E2E test.

The script expects the local Android emulator and iOS simulator described below,
plus an Appium server with UiAutomator2 and XCUITest drivers on port 4723.
It deliberately uses noReset=True and never clears application data.
"""

from pathlib import Path
import os
import sys
import time

from appium import webdriver
from appium.options.android import UiAutomator2Options
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "parity-evidence" / "final"
EVIDENCE.mkdir(parents=True, exist_ok=True)
SERVER = os.environ.get("APPIUM_SERVER", "http://127.0.0.1:4723")
IOS_UDID = "77AA5B73-C27E-4576-BCCD-BDA04CE116F7"


def wait_for(driver, by, value, timeout=15):
    return WebDriverWait(driver, timeout).until(lambda d: d.find_element(by, value))


def ios_double_tap(driver, identifier):
    element = wait_for(driver, AppiumBy.ACCESSIBILITY_ID, identifier)
    driver.execute_script("mobile: doubleTap", {"elementId": element.id})


def ios_open_directory(driver, pane, name, expected_path):
    identifier = f"File-{pane}-{name}"
    for _ in range(2):
        ios_double_tap(driver, identifier)
        try:
            WebDriverWait(driver, 5).until(
                lambda d: not d.find_elements(AppiumBy.ACCESSIBILITY_ID, identifier)
            )
            return
        except Exception:
            pass
    raise AssertionError(f"Could not open {name} in pane {pane}")


def test_ios():
    options = XCUITestOptions()
    options.platform_name = "iOS"
    options.automation_name = "XCUITest"
    options.device_name = "iPhone 15 Pro Max"
    options.udid = IOS_UDID
    options.bundle_id = "com.github.niklaus85.OpenCommander"
    options.no_reset = True
    options.set_capability("appium:forceAppLaunch", True)
    options.set_capability("appium:showXcodeLog", False)
    options.set_capability("appium:wdaLaunchTimeout", 600000)
    # Reuse the already installed simulator WDA runner. This keeps the parity
    # suite isolated from unrelated Xcode builds running on the same machine.
    options.set_capability("appium:usePreinstalledWDA", True)
    options.new_command_timeout = 300

    driver = webdriver.Remote(SERVER, options=options)
    try:
        print("iOS: launch")
        time.sleep(2)
        # Dismiss first-run help if this simulator has not seen it yet.
        for label in ("OK", "ok", "Got it"):
            buttons = driver.find_elements(AppiumBy.ACCESSIBILITY_ID, label)
            if buttons:
                buttons[0].click()
                time.sleep(1)
                break

        print("iOS: open fixture root in both panes")
        ios_open_directory(driver, 1, "OpenCommanderParity", "/OpenCommanderParity")
        ios_open_directory(driver, 2, "OpenCommanderParity", "/OpenCommanderParity")

        print("iOS: drag folder from pane 1 into pane 2")
        source = wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-DragMe")
        target = wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-2-DropHere")
        source_center = {
            "x": source.rect["x"] + source.rect["width"] / 2,
            "y": source.rect["y"] + source.rect["height"] / 2,
        }
        target_center = {
            "x": target.rect["x"] + target.rect["width"] / 2,
            "y": target.rect["y"] + target.rect["height"] / 2,
        }
        driver.execute_script("mobile: dragFromToForDuration", {
            "duration": 1.5,
            "fromX": source_center["x"],
            "fromY": source_center["y"],
            "toX": target_center["x"],
            "toY": target_center["y"],
        })
        ios_open_directory(driver, 2, "DropHere", "/DropHere")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-2-DragMe")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "Up-2").click()

        print("iOS: create ZIP with source name")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore").click()
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "ZipButton").click()
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore.zip")

        print("iOS: browse ZIP")
        ios_open_directory(driver, 1, "FolderBefore.zip", "!/")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore")
        assert "!/" in wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "Path-1").get_attribute("value")

        print("iOS: delete and undo ZIP")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "Up-1").click()
        archive = wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore.zip")
        archive.click()
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "DeleteButton").click()
        alert = wait_for(driver, AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
        alert_buttons = alert.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeButton")
        print("iOS alert buttons:", [button.get_attribute("label") for button in alert_buttons])
        delete_actions = [
            button for button in alert_buttons
            if button.get_attribute("label") == "Delete"
        ]
        assert delete_actions, "Delete confirmation action must be present"
        delete_actions[-1].click()
        WebDriverWait(driver, 15).until(
            lambda d: not d.find_elements(AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore.zip")
        )
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "UndoButton").click()
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore.zip")

        print("iOS: rename and undo")
        ios_open_directory(driver, 1, "Source", "/Source")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-ParityFile.txt").click()
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "RenameButton").click()
        rename_alert = wait_for(driver, AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
        field = rename_alert.find_element(AppiumBy.CLASS_NAME, "XCUIElementTypeTextField")
        field.clear()
        field.send_keys("ParityRenamed.txt")
        driver.execute_script("mobile: tap", {
            "x": rename_alert.rect["x"] + rename_alert.rect["width"] * 0.75,
            "y": rename_alert.rect["y"] + rename_alert.rect["height"] * 0.88,
        })
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-ParityRenamed.txt")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "UndoButton").click()
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-ParityFile.txt")

        print("iOS: operation selector")
        wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "OperationButton").click()
        assert "move" in wait_for(driver, AppiumBy.ACCESSIBILITY_ID, "GlobalStatus").text.lower()
        driver.save_screenshot(str(EVIDENCE / "ios-parity-final.png"))
    finally:
        driver.quit()


def android_text_contains(driver, value, timeout=15):
    selector = f'new UiSelector().textContains("{value}")'
    return wait_for(driver, AppiumBy.ANDROID_UIAUTOMATOR, selector, timeout)


def test_android():
    options = UiAutomator2Options()
    options.platform_name = "Android"
    options.automation_name = "UiAutomator2"
    options.udid = os.environ.get("ANDROID_UDID", "emulator-5554")
    options.app_package = "com.opencommander"
    options.app_activity = ".MainActivity"
    options.no_reset = True
    options.set_capability("appium:forceAppLaunch", True)
    options.new_command_timeout = 300

    driver = webdriver.Remote(SERVER, options=options)
    try:
        print("Android: launch and path entry")
        time.sleep(4)
        print(f"Android: current package={driver.current_package}")
        driver.save_screenshot(str(EVIDENCE / "android-launch.png"))
        paths = driver.find_elements(AppiumBy.CLASS_NAME, "android.widget.EditText")
        assert len(paths) >= 2, "Both commander path fields must be present"
        paths[0].click()
        paths[0].set_value("/sdcard/OpenCommanderParity/Source")
        driver.execute_script("mobile: performEditorAction", {"action": "go"})
        driver.press_keycode(66)
        time.sleep(1)
        refreshed_paths = driver.find_elements(AppiumBy.CLASS_NAME, "android.widget.EditText")
        print("Android path value:", refreshed_paths[0].get_attribute("text"))
        driver.save_screenshot(str(EVIDENCE / "android-after-path.png"))
        print("Android: create and undo ZIP")
        android_text_contains(driver, "ParityFile.txt").click()
        print("Android: selected fixture")
        wait_for(driver, AppiumBy.ANDROID_UIAUTOMATOR, 'new UiSelector().text("ZIP")').click()
        print("Android: ZIP command clicked")
        android_text_contains(driver, "ParityFile.zip")
        print("Android: ZIP created")
        wait_for(driver, AppiumBy.ANDROID_UIAUTOMATOR, 'new UiSelector().text("Undo")').click()
        print("Android: undo clicked")
        WebDriverWait(driver, 15).until(
            lambda d: not d.find_elements(
                AppiumBy.ANDROID_UIAUTOMATOR,
                'new UiSelector().textContains("ParityFile.zip")',
            )
        )
        print("Android: ZIP undo verified")
        driver.save_screenshot(str(EVIDENCE / "android-parity-final.png"))
    finally:
        driver.quit()


if __name__ == "__main__":
    failures = []
    requested = {arg.lower() for arg in sys.argv[1:]}
    tests = (("iOS", test_ios), ("Android", test_android))
    for name, test in tests:
        if requested and name.lower() not in requested:
            continue
        try:
            test()
            print(f"PASS {name}")
        except Exception as exc:  # Test runner prints compact reproduction evidence.
            failures.append((name, exc))
            print(f"FAIL {name}: {exc}", file=sys.stderr)
    if failures:
        raise SystemExit(1)
