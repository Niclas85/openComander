"""Android-emulator QA for OpenCommander's in-app image viewer."""

from pathlib import Path
import time

from appium import webdriver
from appium.options.android import UiAutomator2Options
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait


SERIAL = "emulator-5554"
EVIDENCE = Path("/Users/niklaus/Documents/openComander/parity-evidence/image-viewer")


def wait(driver, by, value, timeout=15):
    return WebDriverWait(driver, timeout).until(
        lambda current: current.find_element(by, value)
    )


def double_tap(driver, element):
    rect = element.rect
    point = {
        "x": round(rect["x"] + rect["width"] / 2),
        "y": round(rect["y"] + rect["height"] / 2),
    }
    element.click()
    driver.execute_script("mobile: doubleClickGesture", point)


def swipe(driver, direction):
    viewer = wait(driver, AppiumBy.ACCESSIBILITY_ID, "ImageViewer")
    driver.execute_script("mobile: swipeGesture", {
        "elementId": viewer.id,
        "direction": direction,
        "percent": 0.75,
        "speed": 1200,
    })


def title(driver):
    return wait(driver, AppiumBy.ACCESSIBILITY_ID, "ImageViewerTitle").text


def page(driver):
    return wait(driver, AppiumBy.ACCESSIBILITY_ID, "ImageViewerPage").text


def file_label(driver, name):
    return wait(
        driver,
        AppiumBy.ANDROID_UIAUTOMATOR,
        f'new UiSelector().textContains("{name}")',
    )


def main():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    options = UiAutomator2Options().load_capabilities({
        "platformName": "Android",
        "appium:automationName": "UiAutomator2",
        "appium:udid": SERIAL,
        "appium:deviceName": SERIAL,
        "appium:appPackage": "com.opencommander",
        "appium:appActivity": ".MainActivity",
        "appium:noReset": True,
        "appium:forceAppLaunch": True,
        "appium:newCommandTimeout": 300,
    })
    driver = webdriver.Remote("http://127.0.0.1:4723", options=options)
    checks = []
    try:
        fields = driver.find_elements(AppiumBy.CLASS_NAME, "android.widget.EditText")
        assert fields, "No path field found"
        fields[0].click()
        fields[0].clear()
        fields[0].send_keys("/storage/emulated/0/Download/OpenCommanderImageQA")
        driver.press_keycode(66)
        try:
            driver.hide_keyboard()
        except Exception:
            pass

        first = file_label(driver, "01-first.png")
        first.click()
        WebDriverWait(driver, 10).until(
            lambda current: any("1/4" in item.text.replace(" ", "")
                                for item in current.find_elements(AppiumBy.CLASS_NAME, "android.widget.TextView"))
        )
        checks.append("single tap selects the image")

        first = file_label(driver, "01-first.png")
        double_tap(driver, first)
        WebDriverWait(driver, 10).until(lambda current: page(current) == "1 / 3")
        assert title(driver) == "01-first.png"
        driver.save_screenshot(str(EVIDENCE / "android-folder-first.png"))
        checks.append("double tap opens the image full screen")

        swipe(driver, "left")
        WebDriverWait(driver, 10).until(lambda current: page(current) == "2 / 3")
        assert title(driver) == "02-second.png"
        driver.save_screenshot(str(EVIDENCE / "android-folder-second.png"))
        checks.append("left swipe advances in sorted folder order")

        time.sleep(0.8)
        swipe(driver, "left")
        WebDriverWait(driver, 10).until(lambda current: page(current) == "3 / 3")
        assert wait(driver, AppiumBy.ACCESSIBILITY_ID, "ImageViewerError").is_displayed()
        driver.save_screenshot(str(EVIDENCE / "android-corrupt-image.png"))
        checks.append("corrupt image fails safely inside the viewer")

        swipe(driver, "left")
        time.sleep(0.3)
        assert page(driver) == "3 / 3"
        swipe(driver, "right")
        WebDriverWait(driver, 10).until(lambda current: page(current) == "2 / 3")
        checks.append("viewer is bounded and supports reverse swiping")

        driver.orientation = "LANDSCAPE"
        assert wait(driver, AppiumBy.ACCESSIBILITY_ID, "ImageViewerClose").is_displayed()
        assert page(driver) == "2 / 3"
        driver.save_screenshot(str(EVIDENCE / "android-landscape.png"))
        driver.orientation = "PORTRAIT"
        checks.append("rotation keeps the viewer state and controls visible")

        wait(driver, AppiumBy.ACCESSIBILITY_ID, "ImageViewerClose").click()
        WebDriverWait(driver, 10).until(lambda current: not current.find_elements(
            AppiumBy.ACCESSIBILITY_ID, "ImageViewerClose"))
        assert file_label(driver, "01-first.png").is_displayed()
        checks.append("close returns to the same folder")

        double_tap(driver, file_label(driver, "gallery.zip"))
        zipped_first = file_label(driver, "01-first.png")
        double_tap(driver, zipped_first)
        WebDriverWait(driver, 10).until(lambda current: page(current) == "1 / 2")
        swipe(driver, "left")
        WebDriverWait(driver, 10).until(lambda current: page(current) == "2 / 2")
        assert title(driver) == "02-second.png"
        driver.save_screenshot(str(EVIDENCE / "android-zip-second.png"))
        checks.append("ZIP images open and swipe in the same order")

        (EVIDENCE / "android-checks.txt").write_text("\n".join(checks) + "\n")
        print("PASS")
        for check in checks:
            print("-", check)
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
