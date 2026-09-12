"""Run the focused operation-toggle check directly against WebDriverAgent."""

import base64
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request


BUNDLE = "com.github.niklaus85.OpenCommander"
WDA = os.environ["WDA_URL"].rstrip("/")
OUT = Path(os.environ["QA_EVIDENCE"])


class Driver:
    def __init__(self):
        body = self.request(
            "POST",
            f"{WDA}/session",
            {"capabilities": {"alwaysMatch": {
                "bundleId": BUNDLE,
                "shouldWaitForQuiescence": False,
            }}},
        )
        self.session = body["value"]["sessionId"]

    @staticmethod
    def request(method, url, payload=None, timeout=30):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    def command(self, method, path, payload=None, timeout=30):
        body = self.request(
            method,
            f"{WDA}/session/{self.session}{path}",
            payload,
            timeout=timeout,
        )
        value = body.get("value")
        if isinstance(value, dict) and value.get("error"):
            raise AssertionError(value)
        return value

    def elements(self, strategy, value):
        result = self.command(
            "POST", "/elements", {"using": strategy, "value": value}
        )
        return [Element(self, next(iter(item.values()))) for item in result]

    def find(self, identifier, timeout=15):
        deadline = time.time() + timeout
        while time.time() < deadline:
            found = self.elements("accessibility id", identifier)
            if found:
                return found[0]
            time.sleep(0.25)
        raise AssertionError(f"Element not found: {identifier}")

    def orientation(self, value):
        self.command("POST", "/orientation", {"orientation": value})

    def window_rect(self):
        return self.command("GET", "/window/rect")

    def screenshot(self, name):
        data = self.command("GET", "/screenshot", timeout=60)
        (OUT / name).write_bytes(base64.b64decode(data))

    def close(self):
        try:
            self.command("DELETE", "")
        except Exception:
            pass


class Element:
    def __init__(self, driver, identifier):
        self.driver = driver
        self.identifier = identifier

    def click(self):
        self.driver.command("POST", f"/element/{self.identifier}/click", {})

    def attribute(self, name):
        return self.driver.command(
            "GET", f"/element/{self.identifier}/attribute/{name}"
        )

    def text(self):
        return self.driver.command("GET", f"/element/{self.identifier}/text")

    def rect(self):
        return self.driver.command("GET", f"/element/{self.identifier}/rect")


def inside(inner, outer):
    return (
        inner["x"] >= outer["x"] - 1
        and inner["y"] >= outer["y"] - 1
        and inner["x"] + inner["width"] <= outer["x"] + outer["width"] + 1
        and inner["y"] + inner["height"] <= outer["y"] + outer["height"] + 1
    )


def select_language(driver, language):
    driver.find("LanguageButton").click()
    driver.find(language).click()
    deadline = time.time() + 10
    while time.time() < deadline:
        if not driver.elements("accessibility id", language):
            break
        time.sleep(0.25)
    time.sleep(0.4)


def no_modal(driver):
    assert not driver.elements("class name", "XCUIElementTypeAlert")
    assert not driver.elements("class name", "XCUIElementTypeSheet")


def test_pair(driver, copy_label, move_label, name, checks):
    operation = driver.find("OperationButton")
    if operation.attribute("label") != copy_label:
        operation.click()
        operation = driver.find("OperationButton")
    assert operation.attribute("label") == copy_label
    assert inside(operation.rect(), driver.find("ActionToolbar").rect())
    assert inside(operation.rect(), driver.window_rect())

    old_status = driver.find("GlobalStatus").text()
    operation.click()
    time.sleep(0.4)
    operation = driver.find("OperationButton")
    assert operation.attribute("label") == move_label
    assert operation.attribute("value") == move_label
    assert driver.find("GlobalStatus").text() != old_status
    no_modal(driver)
    assert inside(operation.rect(), driver.find("ActionToolbar").rect())
    driver.screenshot(f"{name}-move.png")

    old_status = driver.find("GlobalStatus").text()
    operation.click()
    time.sleep(0.4)
    operation = driver.find("OperationButton")
    assert operation.attribute("label") == copy_label
    assert operation.attribute("value") == copy_label
    assert driver.find("GlobalStatus").text() != old_status
    no_modal(driver)
    assert inside(operation.rect(), driver.find("ActionToolbar").rect())
    driver.screenshot(f"{name}-copy.png")
    checks.append(
        f"{name}: direct Copy/Move toggle, state/status update, no dialog, no clipping"
    )


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    driver = Driver()
    checks = []
    try:
        if driver.elements("accessibility id", "OK"):
            driver.find("OK").click()
        for language, copy_label, move_label, code in (
            ("Deutsch", "Kopieren", "Verschieben", "de"),
            ("English", "Copy", "Move", "en"),
        ):
            select_language(driver, language)
            for orientation in ("PORTRAIT", "LANDSCAPE"):
                driver.orientation(orientation)
                time.sleep(0.8)
                test_pair(
                    driver,
                    copy_label,
                    move_label,
                    f"{code}-{orientation.lower()}",
                    checks,
                )
        select_language(driver, "Deutsch")
        driver.orientation("PORTRAIT")
        time.sleep(0.5)
        operation = driver.find("OperationButton")
        if operation.attribute("label") != "Kopieren":
            operation.click()
        driver.screenshot("final-restored.png")
        (OUT / "checks.json").write_text(
            json.dumps(checks, ensure_ascii=False, indent=2) + "\n"
        )
        for check in checks:
            print("PASS " + check, flush=True)
    except Exception:
        driver.screenshot("failure.png")
        raise
    finally:
        driver.close()


if __name__ == "__main__":
    main()
