"""Visible iOS smoke test for the expanded language selector."""

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
LANGUAGE_LABELS = [
    "Deutsch", "English", "Français", "Español", "Italiano", "Português",
    "Nederlands", "简体中文", "日本語", "한국어", "العربية", "हिन्दी",
    "Русский", "Türkçe", "Polski", "Bahasa Indonesia", "Tiếng Việt",
    "ไทย", "Українська", "Svenska",
]


def find(driver, identifier, timeout=20):
    return WebDriverWait(driver, timeout).until(
        lambda current: current.find_element(AppiumBy.ACCESSIBILITY_ID, identifier)
    )


def select(driver, language):
    find(driver, "LanguageButton").click()
    option = find(driver, language)
    option.click()
    time.sleep(0.8)


def inside(inner, outer):
    return (
        inner["x"] >= outer["x"] - 1
        and inner["y"] >= outer["y"] - 1
        and inner["x"] + inner["width"] <= outer["x"] + outer["width"] + 1
        and inner["y"] + inner["height"] <= outer["y"] + outer["height"] + 1
    )


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    options = XCUITestOptions().load_capabilities({
        "platformName": "iOS",
        "appium:automationName": "XCUITest",
        "appium:deviceName": os.environ.get("IOS_DEVICE_NAME", "iPhone"),
        "appium:udid": os.environ["IOS_UDID"],
        "appium:bundleId": BUNDLE,
        "appium:noReset": True,
        "appium:forceAppLaunch": True,
        "appium:newCommandTimeout": 300,
    })
    driver = webdriver.Remote(os.environ["APPIUM_SERVER"], options=options)
    checks = []
    try:
        if driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK"):
            driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK")[0].click()

        select(driver, "简体中文")
        assert find(driver, "LanguageButton").get_attribute("label") == "语言"
        assert find(driver, "OperationButton").get_attribute("label") in ("复制", "移动")
        driver.terminate_app(BUNDLE)
        driver.activate_app(BUNDLE)
        assert find(driver, "LanguageButton").get_attribute("label") == "语言"
        driver.save_screenshot(str(OUT / "ios-zh-Hans-persisted.png"))
        checks.append("Simplified Chinese selection and relaunch persistence")

        select(driver, "العربية")
        language = find(driver, "LanguageButton")
        operation = find(driver, "OperationButton")
        toolbar = find(driver, "ActionToolbar")
        assert language.get_attribute("label") == "اللغة"
        assert operation.get_attribute("label") in ("نسخ", "نقل")
        assert inside(operation.rect, toolbar.rect)
        assert inside(operation.rect, driver.get_window_rect())
        driver.save_screenshot(str(OUT / "ios-arabic-rtl.png"))
        checks.append("Arabic RTL UI, translated controls and unclipped operation button")

        find(driver, "LanguageButton").click()
        available = {element.get_attribute("label") for element in
                     driver.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeButton")}
        assert set(LANGUAGE_LABELS).issubset(available), sorted(set(LANGUAGE_LABELS) - available)
        find(driver, "Deutsch").click()
        assert find(driver, "LanguageButton").get_attribute("label") == "Sprache"
        driver.save_screenshot(str(OUT / "ios-final-german.png"))
        checks.append("All 20 explicit languages exposed; final state restored to German")
        (OUT / "ios-checks.json").write_text(
            json.dumps(checks, ensure_ascii=False, indent=2) + "\n"
        )
        for check in checks:
            print("PASS " + check, flush=True)
    except Exception:
        driver.save_screenshot(str(OUT / "ios-failure.png"))
        raise
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
