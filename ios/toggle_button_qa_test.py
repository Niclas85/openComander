"""Focused physical-iPhone regression for the Copy/Move operation toggle."""

import json
import os
from pathlib import Path
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait


BUNDLE = "com.github.niklaus85.OpenCommander"
OUT = Path(os.environ["QA_EVIDENCE"])


def find(driver, identifier):
    return WebDriverWait(driver, 15).until(
        lambda current: current.find_element(AppiumBy.ACCESSIBILITY_ID, identifier)
    )


def inside(inner, outer):
    return (
        inner["x"] >= outer["x"] - 1
        and inner["y"] >= outer["y"] - 1
        and inner["x"] + inner["width"] <= outer["x"] + outer["width"] + 1
        and inner["y"] + inner["height"] <= outer["y"] + outer["height"] + 1
    )


def select_language(driver, language):
    find(driver, "LanguageButton").click()
    find(driver, language).click()
    WebDriverWait(driver, 10).until(
        lambda current: not current.find_elements(AppiumBy.ACCESSIBILITY_ID, language)
    )
    time.sleep(0.5)


def assert_toggle(driver, copy_label, move_label, prefix, checks):
    operation = find(driver, "OperationButton")
    if operation.get_attribute("label") != copy_label:
        operation.click()
        operation = find(driver, "OperationButton")
    assert operation.get_attribute("label") == copy_label
    assert inside(operation.rect, find(driver, "ActionToolbar").rect)
    assert inside(operation.rect, driver.get_window_rect())

    status_before = find(driver, "GlobalStatus").text
    operation.click()
    time.sleep(0.4)
    operation = find(driver, "OperationButton")
    assert operation.get_attribute("label") == move_label
    assert operation.get_attribute("value") == move_label
    assert find(driver, "GlobalStatus").text != status_before
    assert not driver.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
    assert not driver.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeSheet")
    assert inside(operation.rect, find(driver, "ActionToolbar").rect)
    driver.save_screenshot(str(OUT / f"{prefix}-move.png"))

    status_before = find(driver, "GlobalStatus").text
    operation.click()
    time.sleep(0.4)
    operation = find(driver, "OperationButton")
    assert operation.get_attribute("label") == copy_label
    assert operation.get_attribute("value") == copy_label
    assert find(driver, "GlobalStatus").text != status_before
    assert not driver.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
    assert not driver.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeSheet")
    assert inside(operation.rect, find(driver, "ActionToolbar").rect)
    driver.save_screenshot(str(OUT / f"{prefix}-copy.png"))
    checks.append(f"{prefix}: Copy/Move toggles directly in both directions without a dialog")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    caps = {
        "platformName": "iOS",
        "appium:automationName": "XCUITest",
        "appium:deviceName": os.environ.get("IOS_DEVICE_NAME", "iPhone 11"),
        "appium:platformVersion": os.environ.get("IOS_VERSION", "26.6.1"),
        "appium:udid": os.environ["IOS_UDID"],
        "appium:bundleId": BUNDLE,
        "appium:noReset": True,
        "appium:forceAppLaunch": True,
        "appium:newCommandTimeout": 300,
    }
    if os.environ.get("WDA_URL"):
        caps["appium:webDriverAgentUrl"] = os.environ["WDA_URL"]
    else:
        caps.update({
            "appium:xcodeOrgId": os.environ.get("IOS_TEAM_ID", "WB497999XX"),
            "appium:xcodeSigningId": "Apple Development",
            "appium:updatedWDABundleId": "vip.traveltrack.WebDriverAgentRunner",
            "appium:derivedDataPath": "/tmp/opencommander-toggle-wda",
            "appium:useNewWDA": True,
            "appium:wdaLocalPort": 8153,
            "appium:wdaRemotePort": 8100,
            "appium:wdaLaunchTimeout": 180000,
            "appium:wdaStartupRetries": 2,
            "appium:showXcodeLog": True,
        })

    driver = webdriver.Remote(
        os.environ.get("APPIUM_SERVER", "http://127.0.0.1:4753/wd/hub"),
        options=XCUITestOptions().load_capabilities(caps),
    )
    checks = []
    try:
        driver.update_settings({"waitForIdleTimeout": 0.5, "animationCoolOffTimeout": 0.2})
        if driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK"):
            driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK")[0].click()
        for language, copy_label, move_label, code in (
            ("Deutsch", "Kopieren", "Verschieben", "de"),
            ("English", "Copy", "Move", "en"),
        ):
            select_language(driver, language)
            for orientation in ("PORTRAIT", "LANDSCAPE"):
                driver.orientation = orientation
                time.sleep(0.8)
                assert_toggle(
                    driver,
                    copy_label,
                    move_label,
                    f"{code}-{orientation.lower()}",
                    checks,
                )
        select_language(driver, "Deutsch")
        driver.orientation = "PORTRAIT"
        time.sleep(0.5)
        if find(driver, "OperationButton").get_attribute("label") != "Kopieren":
            find(driver, "OperationButton").click()
        driver.save_screenshot(str(OUT / "final-restored.png"))
        (OUT / "checks.json").write_text(
            json.dumps(checks, ensure_ascii=False, indent=2) + "\n"
        )
        for check in checks:
            print("PASS " + check, flush=True)
    except Exception:
        driver.save_screenshot(str(OUT / "failure.png"))
        (OUT / "failure.xml").write_text(driver.page_source)
        raise
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
