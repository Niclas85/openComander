"""Narrow physical-device ZIP diagnostic, only using the QA fixture."""
import os
import base64
import time
from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from app_store_qa_test import button, select_language, EVIDENCE

options = XCUITestOptions().load_capabilities({
    "platformName": "iOS", "appium:automationName": "XCUITest",
    "appium:deviceName": "iPhone 11", "appium:udid": os.environ["IOS_UDID"],
    "appium:platformVersion": "26.6.1",
    "appium:bundleId": "com.github.niklaus85.OpenCommander",
    "appium:noReset": True, "appium:forceAppLaunch": True,
    "appium:webDriverAgentUrl": os.environ["WDA_URL"],
})
driver = webdriver.Remote(os.environ["APPIUM_SERVER"], options=options)
try:
    if os.environ.get("QA_PUSH_FIXTURE"):
        fixture = os.environ.get("QA_FIXTURE", "OpenCommanderParity")
        for name, content in {
            "Source/ParityFile.txt": "OpenCommander iPhone QA content\n",
            "FolderBefore/Inside.txt": "ZIP round trip on physical iPhone\n",
            "DragMe/Drag.txt": "Copy and move integrity\n",
            "AReverseSource/Reverse.txt": "Reverse drag integrity\n",
            "DropHere/.qa": "test folder\n",
            "AReverseTarget/.qa": "test folder\n",
        }.items():
            driver.push_file("@com.github.niklaus85.OpenCommander:documents/" + fixture + "/" + name,
                             base64.b64encode(content.encode()).decode())
    select_language(driver, "English")
    field = button(driver, "Path-1")
    field.clear()
    field.send_keys("/Documents/" + os.environ.get("QA_FIXTURE", "OpenCommanderParity") + "\n")
    button(driver, "File-1-FolderBefore").click()
    button(driver, "ZipButton").click()
    time.sleep(3)
    print("ZIP status:", button(driver, "GlobalStatus").text, flush=True)
    driver.save_screenshot(str(EVIDENCE / "zip-probe.png"))
    (EVIDENCE / "zip-probe.xml").write_text(driver.page_source)
    archives = driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "File-1-FolderBefore.zip")
    if archives:
        button(driver, "UndoButton").click()
        print("ZIP created and undone", flush=True)
finally:
    driver.quit()
