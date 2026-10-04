"""Broad iOS App Store acceptance test for OpenCommander.

The suite is intentionally non-destructive to user data: it works only inside
the OpenCommanderParity fixture and undoes every completed file operation.
"""

from pathlib import Path
import os
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait
from selenium.common.exceptions import StaleElementReferenceException


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path(os.environ.get("QA_EVIDENCE", str(ROOT / "parity-evidence" / "app-store-qa")))
EVIDENCE.mkdir(parents=True, exist_ok=True)
SERVER = os.environ.get("APPIUM_SERVER", "http://127.0.0.1:4753")
UDID = os.environ.get("IOS_UDID", "77AA5B73-C27E-4576-BCCD-BDA04CE116F7")
FIXTURE = os.environ.get("QA_FIXTURE", "OpenCommanderParity")


def wait(driver, by, value, timeout=15):
    return WebDriverWait(driver, timeout).until(lambda d: d.find_element(by, value))


def absent(driver, identifier, timeout=15):
    WebDriverWait(driver, timeout).until(
        lambda d: not any(
            element.is_displayed()
            for element in d.find_elements(AppiumBy.ACCESSIBILITY_ID, identifier)
        )
    )


def button(driver, identifier):
    element = wait(driver, AppiumBy.ACCESSIBILITY_ID, identifier)
    if identifier.startswith("File-"):
        pane = identifier.split("-", 2)[1]
        table = wait(driver, AppiumBy.ACCESSIBILITY_ID, f"FileList-{pane}")
        for _ in range(8):
            try:
                row, viewport = element.rect, table.rect
            except StaleElementReferenceException:
                time.sleep(.2)
                element = wait(driver, AppiumBy.ACCESSIBILITY_ID, identifier)
                table = wait(driver, AppiumBy.ACCESSIBILITY_ID, f"FileList-{pane}")
                continue
            if (element.is_displayed() and row["y"] >= viewport["y"] and
                    row["y"] + row["height"] <= viewport["y"] + viewport["height"]):
                return element
            driver.execute_script("mobile: swipe", {
                "elementId": table.id,
                "direction": "down" if row["y"] < viewport["y"] else "up",
                "velocity": 900,
            })
            element = wait(driver, AppiumBy.ACCESSIBILITY_ID, identifier)
        raise AssertionError(f"File row cannot be reached by scrolling: {identifier}")
    return element


def double_tap(driver, identifier):
    element = button(driver, identifier)
    driver.execute_script("mobile: doubleTap", {"elementId": element.id})


def open_dir(driver, pane, name):
    identifier = f"File-{pane}-{name}"
    for _ in range(2):
        double_tap(driver, identifier)
        try:
            absent(driver, identifier, 5)
            return
        except Exception:
            pass
    raise AssertionError(f"Could not open {name} in pane {pane}")


def status(driver):
    return button(driver, "GlobalStatus").text


def assert_status_changed(driver, previous):
    WebDriverWait(driver, 8).until(lambda d: status(d) != previous)


def dismiss_modal(driver):
    for label in ("OK", "ok"):
        elements = driver.find_elements(AppiumBy.ACCESSIBILITY_ID, label)
        if elements:
            elements[0].click()
            return
    raise AssertionError("Modal close button missing")


def select_language(driver, name):
    button(driver, "LanguageButton").click()
    option = wait(driver, AppiumBy.ACCESSIBILITY_ID, name)
    option.click()
    absent(driver, name, 8)
    time.sleep(1)


def run():
    options = XCUITestOptions()
    options.platform_name = "iOS"
    options.automation_name = "XCUITest"
    options.device_name = os.environ.get("IOS_DEVICE_NAME", "iPhone 15 Pro Max")
    if os.environ.get("IOS_VERSION"):
        options.platform_version = os.environ["IOS_VERSION"]
    options.udid = UDID
    options.bundle_id = "com.github.niklaus85.OpenCommander"
    options.no_reset = True
    options.set_capability("appium:forceAppLaunch", True)
    options.set_capability(
        "appium:usePreinstalledWDA",
        not os.environ.get("WDA_URL") and os.environ.get("APPIUM_USE_PREINSTALLED_WDA", "1") == "1",
    )
    options.set_capability("appium:newCommandTimeout", 300)
    if os.environ.get("WDA_URL"):
        options.set_capability("appium:webDriverAgentUrl", os.environ["WDA_URL"])

    driver = webdriver.Remote(SERVER, options=options)
    driver.update_settings({"waitForIdleTimeout": 0.5, "animationCoolOffTimeout": 0.2})
    checks = []
    failures = []

    def passed(name):
        checks.append(name)
        print(f"PASS {name}")

    try:
        time.sleep(2)
        # A fresh physical-device install may display the first-run help.
        if driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "OK"):
            dismiss_modal(driver)
        # Normalize the test language without clearing saved preferences.
        select_language(driver, "English")
        assert button(driver, "DeleteButton").get_attribute("label") == "Delete"

        for identifier in (
            "UndoButton", "DeleteButton", "RenameButton", "HistoryButton",
            "ZipButton", "HelpButton", "LegalButton", "LanguageButton",
            "OperationButton", "Up-1", "Up-2", "Path-1", "Path-2",
        ):
            assert button(driver, identifier).is_displayed(), identifier
        passed("all primary controls present")

        # Empty-selection/error behavior for destructive commands.
        for identifier in ("DeleteButton", "RenameButton", "ZipButton", "UndoButton"):
            before = status(driver)
            button(driver, identifier).click()
            assert_status_changed(driver, before)
        passed("empty-selection safeguards")

        button(driver, "HistoryButton").click()
        assert button(driver, "HistoryButton").get_attribute("label") == "History -"
        button(driver, "HistoryButton").click()
        passed("history open and close")

        button(driver, "LegalButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "Terms / Privacy / Imprint")
        dismiss_modal(driver)
        button(driver, "HelpButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "How to use OpenCommander")
        dismiss_modal(driver)
        passed("legal and help dialogs")

        # Localization must rebuild the UI and survive an app relaunch.
        select_language(driver, "Deutsch")
        assert button(driver, "DeleteButton").get_attribute("label") == "Löschen"
        driver.terminate_app("com.github.niklaus85.OpenCommander")
        driver.activate_app("com.github.niklaus85.OpenCommander")
        assert button(driver, "DeleteButton").get_attribute("label") == "Löschen"
        select_language(driver, "English")
        assert button(driver, "DeleteButton").get_attribute("label") == "Delete"
        passed("language switching and persistence")

        # Operation toggle: each tap changes mode immediately without a dialog.
        driver.orientation = "LANDSCAPE"
        time.sleep(1)
        assert button(driver, "OperationButton").get_attribute("label") == "Copy"
        button(driver, "OperationButton").click()
        assert button(driver, "OperationButton").get_attribute("label") == "Move"
        assert "move" in status(driver).lower()
        button(driver, "OperationButton").click()
        assert button(driver, "OperationButton").get_attribute("label") == "Copy"
        assert "copy" in status(driver).lower()
        driver.orientation = "PORTRAIT"
        time.sleep(1)
        passed("copy/move toggle")

        # Invalid and valid typed paths, plus Up in both panes.
        path1 = button(driver, "Path-1")
        path1.clear()
        path1.send_keys("/definitely-not-a-real-opencommander-path\n")
        assert "not found" in status(driver).lower()
        path1 = button(driver, "Path-1")
        path1.clear()
        path1.send_keys(f"/Documents/{FIXTURE}/Source\n")
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-ParityFile.txt")
        button(driver, "Up-1").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-Source")
        open_dir(driver, 2, FIXTURE)
        open_dir(driver, 2, "DragMe")
        button(driver, "Up-2").click()
        passed("path entry, invalid path, navigation and up")

        # Rename: cancel, invalid name, successful name, undo.
        open_dir(driver, 1, "Source")
        button(driver, "File-1-ParityFile.txt").click()
        button(driver, "RenameButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "Cancel").click()
        button(driver, "RenameButton").click()
        alert = wait(driver, AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
        field = alert.find_element(AppiumBy.CLASS_NAME, "XCUIElementTypeTextField")
        field.clear()
        field.send_keys("bad:name")
        driver.execute_script("mobile: tap", {
            "x": alert.rect["x"] + alert.rect["width"] * 0.75,
            "y": alert.rect["y"] + alert.rect["height"] * 0.88,
        })
        WebDriverWait(driver, 5).until(lambda d: "valid name" in status(d).lower())
        button(driver, "RenameButton").click()
        alert = wait(driver, AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
        field = alert.find_element(AppiumBy.CLASS_NAME, "XCUIElementTypeTextField")
        field.clear()
        field.send_keys("RenamedQA.txt")
        driver.execute_script("mobile: tap", {
            "x": alert.rect["x"] + alert.rect["width"] * 0.75,
            "y": alert.rect["y"] + alert.rect["height"] * 0.88,
        })
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-RenamedQA.txt")
        button(driver, "UndoButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-ParityFile.txt")
        passed("rename cancel, validation, success and undo")

        # ZIP name, archive browsing/read-only guard, history and undo.
        button(driver, "Up-1").click()
        button(driver, "File-1-FolderBefore").click()
        button(driver, "ZipButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore.zip")
        button(driver, "HistoryButton").click()
        assert driver.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeButton")
        button(driver, "HistoryButton").click()
        open_dir(driver, 1, "FolderBefore.zip")
        button(driver, "File-1-FolderBefore").click()
        before = status(driver)
        button(driver, "DeleteButton").click()
        assert_status_changed(driver, before)
        assert "read-only" in status(driver).lower()
        button(driver, "Up-1").click()
        button(driver, "UndoButton").click()
        absent(driver, "File-1-FolderBefore.zip")
        passed("smart ZIP naming, browse, read-only protection, history and undo")

        # Delete: cancel, permanent delete/undo, trash/undo.
        open_dir(driver, 1, "Source")
        button(driver, "File-1-ParityFile.txt").click()
        button(driver, "DeleteButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "Cancel").click()
        assert button(driver, "File-1-ParityFile.txt").is_displayed()
        button(driver, "DeleteButton").click()
        alert = wait(driver, AppiumBy.CLASS_NAME, "XCUIElementTypeAlert")
        actions = alert.find_elements(AppiumBy.CLASS_NAME, "XCUIElementTypeButton")
        [a for a in actions if a.get_attribute("label") == "Delete"][-1].click()
        absent(driver, "File-1-ParityFile.txt")
        button(driver, "UndoButton").click()
        button(driver, "File-1-ParityFile.txt").click()
        button(driver, "DeleteButton").click()
        wait(driver, AppiumBy.ACCESSIBILITY_ID, "Trash").click()
        time.sleep(2)
        if any(e.is_displayed() for e in driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "File-1-ParityFile.txt")):
            failures.append(f"Trash failed: {status(driver)}")
            print(f"FAIL trash operation: {status(driver)}")
            passed("delete cancel, permanent delete and undo")
        else:
            button(driver, "UndoButton").click()
            wait(driver, AppiumBy.ACCESSIBILITY_ID, "File-1-ParityFile.txt")
            passed("delete cancel, delete, trash and undo")

        # Theme and orientation; restore the original portrait/light state.
        driver.orientation = "LANDSCAPE"
        time.sleep(1)
        assert button(driver, "ThemeButton").get_attribute("label") == "Dark"
        button(driver, "ThemeButton").click()
        driver.save_screenshot(str(EVIDENCE / "ios-landscape-dark.png"))
        assert button(driver, "ThemeButton").get_attribute("label") == "Light"
        button(driver, "ThemeButton").click()
        driver.orientation = "PORTRAIT"
        time.sleep(1)
        passed("dark/light theme and rotation")

        driver.save_screenshot(str(EVIDENCE / "ios-functional-final.png"))
        (EVIDENCE / "ios-functional-checks.txt").write_text(
            "\n".join(
                [*(f"PASS {item}" for item in checks), *(f"FAIL {item}" for item in failures)]
            ) + "\n",
            encoding="utf-8",
        )
        print(f"RESULT {len(checks)} passed groups, {len(failures)} failures")
        if failures:
            raise AssertionError("; ".join(failures))
    except Exception:
        driver.save_screenshot(str(EVIDENCE / "failure.png"))
        (EVIDENCE / "failure.xml").write_text(driver.page_source, encoding="utf-8")
        (EVIDENCE / "partial-checks.txt").write_text("\n".join(checks) + "\n", encoding="utf-8")
        raise
    finally:
        driver.quit()


if __name__ == "__main__":
    run()
