"""Physical iPhone drag/drop checks with byte-level verification of QA fixtures.

Requires the isolated OpenCommanderParity fixture prepared on the device.
Never reads or modifies files outside that fixture.
"""
import json
import base64
import io
import zipfile
import os
from pathlib import Path
import subprocess
import time

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait

from app_store_qa_test import button, open_dir, select_language

BUNDLE = "com.github.niklaus85.OpenCommander"
EVIDENCE = Path(os.environ["QA_EVIDENCE"])
DEVICE = os.environ["IOS_UDID"]
FIXTURE = os.environ.get("QA_FIXTURE", "OpenCommanderParity")


def copy_fixture(stage):
    target = EVIDENCE / stage
    target.mkdir(parents=True, exist_ok=False)
    subprocess.run([
        "xcrun", "devicectl", "device", "copy", "from", "--device", DEVICE,
        "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
        "--source", f"Documents/{FIXTURE}", "--destination", str(target),
    ], check=True, capture_output=True, text=True)
    return target


def navigate(driver, pane, path):
    field = button(driver, f"Path-{pane}")
    field.clear()
    field.send_keys(path + "\n")
    time.sleep(1)


def drag(driver, source, target, landscape=False):
    if landscape:
        driver.orientation = "LANDSCAPE"
        time.sleep(1)
    # File lists may legitimately scroll; the toolbar must never need scrolling.
    # Make each row visible in its own pane before deriving gesture coordinates.
    for identifier in (source, target):
        pane = identifier.split("-", 2)[1]
        table = button(driver, f"FileList-{pane}")
        for attempt in range(8):
            row = button(driver, identifier).rect
            viewport = table.rect
            if (row["y"] >= viewport["y"] and
                    row["y"] + row["height"] <= viewport["y"] + viewport["height"]):
                break
            driver.execute_script("mobile: swipe", {
                "elementId": table.id,
                "direction": "down" if row["y"] < viewport["y"] else "up",
                "velocity": 900,
            })
        else:
            raise AssertionError(f"File row cannot be reached by scrolling: {identifier}")
    source_rect = button(driver, source).rect
    target_rect = button(driver, target).rect
    if landscape:
        window = driver.get_window_rect()
        assert window['width'] > window['height'], 'Device rotated away from landscape before drag'
    driver.execute_script("mobile: dragFromToForDuration", {
        "duration": 1.5,
        "fromX": source_rect["x"] + source_rect["width"] / 2,
        "fromY": source_rect["y"] + source_rect["height"] / 2,
        "toX": target_rect["x"] + target_rect["width"] / 2,
        "toY": target_rect["y"] + target_rect["height"] / 2,
    })
    time.sleep(2)
    if landscape:
        window = driver.get_window_rect()
        assert window['width'] > window['height'], 'Device rotated away from landscape during drag'


def main():
    options = XCUITestOptions().load_capabilities({
        "platformName": "iOS", "appium:automationName": "XCUITest",
        "appium:deviceName": "iPhone 11", "appium:udid": DEVICE,
        "appium:bundleId": BUNDLE, "appium:noReset": True,
        "appium:forceAppLaunch": True, "appium:newCommandTimeout": 300,
        "appium:webDriverAgentUrl": os.environ["WDA_URL"],
    })
    driver = webdriver.Remote(os.environ["APPIUM_SERVER"], options=options)
    driver.update_settings({"waitForIdleTimeout": 0.5, "animationCoolOffTimeout": 0.2})
    checks = []

    def passed(name):
        checks.append(name)
        print("PASS " + name, flush=True)

    try:
        select_language(driver, "English")
        driver.orientation = "PORTRAIT"
        for pane in (1, 2):
            navigate(driver, pane, f"/Documents/{FIXTURE}")
        driver.save_screenshot(str(EVIDENCE / "iphone-drag-before.png"))

        button(driver, "File-1-FolderBefore").click()
        button(driver, "ZipButton").click()
        button(driver, "File-1-FolderBefore.zip")
        archive_bytes = base64.b64decode(driver.pull_file(
            f"@{BUNDLE}:documents/{FIXTURE}/FolderBefore.zip"))
        (EVIDENCE / "verified-device.zip").write_bytes(archive_bytes)
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
            assert archive.testzip() is None
            assert archive.read("FolderBefore/Inside.txt") == b"ZIP round trip on physical iPhone\n"
        button(driver, "UndoButton").click()
        passed("created ZIP passes CRC and preserves exact file contents")

        drag(driver, "File-1-DragMe", "File-2-DropHere")
        files = copy_fixture("copy-forward")
        expected = b"Copy and move integrity\n"
        assert (files / "DragMe/Drag.txt").read_bytes() == expected
        assert (files / "DropHere/DragMe/Drag.txt").read_bytes() == expected
        passed("copy top to bottom preserves source and exact bytes")

        # Give the existing destination different contents, so replacement
        # and undo can be distinguished from a no-op using real file bytes.
        existing = EVIDENCE / "existing-destination.txt"
        original_destination = b"Existing destination must survive cancel and undo\n"
        existing.write_bytes(original_destination)
        driver.push_file(f"@{BUNDLE}:documents/{FIXTURE}/DropHere/DragMe/Drag.txt",
                         base64.b64encode(original_destination).decode())
        drag(driver, "File-1-DragMe", "File-2-DropHere")
        button(driver, "Cancel").click()
        files = copy_fixture("conflict-cancel")
        assert (files / "DropHere/DragMe/Drag.txt").read_bytes() == original_destination
        passed("collision cancel preserves existing destination")

        drag(driver, "File-1-DragMe", "File-2-DropHere")
        button(driver, "Replace").click()
        time.sleep(1)
        files = copy_fixture("conflict-replace")
        assert (files / "DropHere/DragMe/Drag.txt").read_bytes() == expected
        button(driver, "UndoButton").click()
        time.sleep(1)
        files = copy_fixture("conflict-replace-undo")
        assert (files / "DropHere/DragMe/Drag.txt").read_bytes() == original_destination
        passed("collision replace and undo restore previous destination bytes")

        drag(driver, "File-1-DragMe", "File-2-DropHere")
        button(driver, "Keep").click()
        time.sleep(1)
        files = copy_fixture("conflict-keep")
        contents = [p.read_bytes() for p in (files / "DropHere").rglob("Drag.txt")]
        assert sorted(contents) == sorted([expected, original_destination])
        button(driver, "UndoButton").click()
        time.sleep(1)
        files = copy_fixture("conflict-keep-undo")
        assert [p.read_bytes() for p in (files / "DropHere").rglob("Drag.txt")] == [original_destination]
        passed("collision keep creates separate copy and undo preserves original")

        button(driver, "UndoButton").click()
        time.sleep(1)
        files = copy_fixture("copy-forward-undo")
        assert not (files / "DropHere/DragMe").exists()
        assert (files / "DragMe/Drag.txt").read_bytes() == expected
        passed("undo copy removes only created destination")

        drag(driver, "File-2-AReverseSource", "File-1-AReverseTarget")
        files = copy_fixture("copy-reverse")
        expected_reverse = b"Reverse drag integrity\n"
        assert (files / "AReverseSource/Reverse.txt").read_bytes() == expected_reverse
        assert (files / "AReverseTarget/AReverseSource/Reverse.txt").read_bytes() == expected_reverse
        passed("copy bottom to top preserves exact bytes")
        driver.save_screenshot(str(EVIDENCE / "iphone-drag-reverse.png"))
        button(driver, "UndoButton").click()
        time.sleep(1)

        driver.orientation = "LANDSCAPE"
        if button(driver, "OperationButton").get_attribute("label") != "Move":
            button(driver, "OperationButton").click()
        driver.orientation = "PORTRAIT"
        time.sleep(1)
        drag(driver, "File-1-DragMe", "File-2-DropHere")
        files = copy_fixture("move-forward")
        assert not (files / "DragMe").exists()
        assert (files / "DropHere/DragMe/Drag.txt").read_bytes() == expected
        passed("move removes source and preserves destination bytes")
        button(driver, "UndoButton").click()
        time.sleep(1)
        files = copy_fixture("move-forward-undo")
        assert (files / "DragMe/Drag.txt").read_bytes() == expected
        assert not (files / "DropHere/DragMe").exists()
        passed("undo move restores source and removes destination")

        driver.orientation = "LANDSCAPE"
        if button(driver, "OperationButton").get_attribute("label") != "Copy":
            button(driver, "OperationButton").click()
        time.sleep(1)
        window = driver.get_window_rect()
        for pane in (1, 2):
            rect = button(driver, f"Pane-{pane}").rect
            assert rect["x"] >= 0 and rect["x"] + rect["width"] <= window["width"]
        drag(driver, "File-1-DragMe", "File-2-DropHere", landscape=True)
        files = copy_fixture("landscape-copy")
        assert (files / "DragMe/Drag.txt").read_bytes() == expected
        assert (files / "DropHere/DragMe/Drag.txt").read_bytes() == expected
        button(driver, "UndoButton").click()
        time.sleep(1)
        passed("landscape panes remain on screen and copy works left to right")

        if button(driver, "OperationButton").get_attribute("label") != "Move":
            button(driver, "OperationButton").click()
        drag(driver, "File-2-AReverseSource", "File-1-AReverseTarget", landscape=True)
        files = copy_fixture("landscape-move")
        assert not (files / "AReverseSource").exists()
        assert (files / "AReverseTarget/AReverseSource/Reverse.txt").read_bytes() == expected_reverse
        button(driver, "UndoButton").click()
        time.sleep(1)
        files = copy_fixture("landscape-move-undo")
        assert (files / "AReverseSource/Reverse.txt").read_bytes() == expected_reverse
        assert not (files / "AReverseTarget/AReverseSource").exists()
        passed("landscape move right to left and undo preserve exact bytes")
        if button(driver, "OperationButton").get_attribute("label") != "Copy":
            button(driver, "OperationButton").click()
        time.sleep(1)
        driver.save_screenshot(str(EVIDENCE / "iphone-landscape-final.png"))
        driver.orientation = "PORTRAIT"
        select_language(driver, "Deutsch")
        driver.save_screenshot(str(EVIDENCE / "iphone-final.png"))
        (EVIDENCE / "drag-checks.json").write_text(json.dumps(checks, indent=2) + "\n")
    except Exception:
        driver.save_screenshot(str(EVIDENCE / "drag-failure.png"))
        (EVIDENCE / "drag-failure.xml").write_text(driver.page_source)
        print("Completed checks:", checks, flush=True)
        raise
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
