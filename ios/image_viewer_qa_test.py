"""iPhone and simulator QA for the in-app image viewer and ZIP gallery."""

import base64
import os
from pathlib import Path
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait


BUNDLE = "com.github.niklaus85.OpenCommander"
DEVICE = os.environ.get("IOS_UDID", "00008030-000E54823A91402E")
EVIDENCE = Path(os.environ.get(
    "QA_EVIDENCE",
    "/Users/niklaus/Documents/openComander/parity-evidence/image-viewer",
))
FIXTURES = Path(os.environ.get("QA_FIXTURES", "/tmp/opencommander-image-qa"))


def find(driver, identifier, timeout=20):
    return WebDriverWait(driver, timeout).until(
        lambda current: current.find_element(AppiumBy.ACCESSIBILITY_ID, identifier)
    )


def wait_text(driver, identifier, expected):
    return WebDriverWait(driver, 15).until(
        lambda current: find(current, identifier).text == expected
    )


def double_tap(driver, element):
    driver.execute_script("mobile: doubleTap", {"elementId": element.id})


def swipe(driver, direction):
    image = find(driver, "ImageViewerImage")
    driver.execute_script("mobile: swipe", {
        "direction": direction,
        "elementId": image.id,
        "velocity": 1200,
    })


def assert_visible_in_window(driver, element):
    window = driver.get_window_rect()
    rect = element.rect
    assert rect["x"] >= 0 and rect["y"] >= 0
    assert rect["x"] + rect["width"] <= window["width"] + 1
    assert rect["y"] + rect["height"] <= window["height"] + 1


def main():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    simulator = os.environ.get("IOS_SIMULATOR") == "1"
    caps = {
        "platformName": "iOS",
        "appium:automationName": "XCUITest",
        "appium:deviceName": os.environ.get("IOS_DEVICE_NAME", "iPhone 11"),
        "appium:platformVersion": os.environ.get("IOS_VERSION", "26.6.1"),
        "appium:udid": DEVICE,
        "appium:bundleId": BUNDLE,
        "appium:noReset": True,
        "appium:forceAppLaunch": True,
        "appium:newCommandTimeout": 300,
    }
    if not simulator:
        caps.update({
            "appium:xcodeOrgId": os.environ.get("IOS_TEAM_ID", "WB497999XX"),
            "appium:xcodeSigningId": "Apple Development",
            "appium:updatedWDABundleId": "vip.traveltrack.WebDriverAgentRunner",
            "appium:derivedDataPath": "/tmp/opencommander-image-viewer-wda",
            "appium:useNewWDA": True,
            "appium:wdaLocalPort": 8153,
            "appium:wdaRemotePort": 8100,
            "appium:wdaLaunchTimeout": 180000,
            "appium:wdaStartupRetries": 2,
        })
    driver = webdriver.Remote(
        os.environ.get("APPIUM_SERVER", "http://127.0.0.1:4723"),
        options=XCUITestOptions().load_capabilities(caps),
    )
    checks = []
    try:
        driver.update_settings({"waitForIdleTimeout": 0.5, "animationCoolOffTimeout": 0.2})
        for _ in range(3):
            if driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK"):
                driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK")[0].click()
                time.sleep(0.3)

        if not simulator:
            for name in ("01-first.png", "02-second.png", "gallery.zip"):
                payload = base64.b64encode((FIXTURES / name).read_bytes()).decode()
                driver.push_file(f"@{BUNDLE}:documents/OpenCommanderImageQA/{name}", payload)
            driver.push_file(
                f"@{BUNDLE}:documents/OpenCommanderImageQA/03-corrupt.png",
                base64.b64encode(b"not an image").decode(),
            )

        fixture_folder = "ImageViewerQA" if simulator else "OpenCommanderImageQA"
        path = find(driver, "Path-1")
        path.clear()
        path.send_keys(f"/Documents/{fixture_folder}\n")
        first = find(driver, "File-1-01-first.png")

        first.click()
        assert find(driver, "Selection-1").text.replace(" ", "").startswith("1/")
        checks.append("single tap still selects the image")

        first = find(driver, "File-1-01-first.png")
        double_tap(driver, first)
        wait_text(driver, "ImageViewerPage", "1 / 3")
        assert find(driver, "ImageViewerTitle").text == "01-first.png"
        assert_visible_in_window(driver, find(driver, "ImageViewerClose"))
        assert_visible_in_window(driver, find(driver, "ImageViewerPage"))
        driver.save_screenshot(str(EVIDENCE / "iphone-folder-first.png"))
        checks.append("double tap opens the first folder image full screen")

        swipe(driver, "left")
        wait_text(driver, "ImageViewerPage", "2 / 3")
        assert find(driver, "ImageViewerTitle").text == "02-second.png"
        driver.save_screenshot(str(EVIDENCE / "iphone-folder-second.png"))
        checks.append("left swipe advances in the sorted folder order")

        swipe(driver, "left")
        wait_text(driver, "ImageViewerPage", "3 / 3")
        assert find(driver, "ImageViewerError").is_displayed()
        driver.save_screenshot(str(EVIDENCE / "iphone-corrupt-image.png"))
        checks.append("corrupt image fails safely without leaving the viewer")

        swipe(driver, "left")
        time.sleep(0.4)
        assert find(driver, "ImageViewerPage").text == "3 / 3"
        swipe(driver, "right")
        wait_text(driver, "ImageViewerPage", "2 / 3")
        checks.append("viewer is bounded and supports reverse swiping")

        driver.orientation = "LANDSCAPE"
        time.sleep(0.8)
        assert_visible_in_window(driver, find(driver, "ImageViewerClose"))
        assert_visible_in_window(driver, find(driver, "ImageViewerPage"))
        driver.save_screenshot(str(EVIDENCE / "iphone-landscape.png"))
        driver.orientation = "PORTRAIT"
        find(driver, "ImageViewerClose").click()
        WebDriverWait(driver, 10).until(
            lambda current: not current.find_elements(AppiumBy.ACCESSIBILITY_ID, "ImageViewerClose")
        )
        assert find(driver, "File-1-01-first.png").is_displayed()
        checks.append("rotation and close return safely to the same folder")

        double_tap(driver, find(driver, "File-1-gallery.zip"))
        zipped_first = find(driver, "File-1-01-first.png")
        double_tap(driver, zipped_first)
        wait_text(driver, "ImageViewerPage", "1 / 2")
        swipe(driver, "left")
        wait_text(driver, "ImageViewerPage", "2 / 2")
        assert find(driver, "ImageViewerTitle").text == "02-second.png"
        driver.save_screenshot(str(EVIDENCE / "iphone-zip-second.png"))
        checks.append("ZIP folder images open and swipe in the same order")

        find(driver, "ImageViewerClose").click()
        (EVIDENCE / "iphone-checks.txt").write_text("\n".join(checks) + "\n")
        print("PASS")
        for check in checks:
            print("-", check)
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
