from appium import webdriver
from appium.webdriver.common.appiumby import AppiumBy
from appium.options.ios import XCUITestOptions
import time

options = XCUITestOptions()
options.platform_name = 'iOS'
options.device_name = 'iPhone 15 Pro Max'
options.automation_name = 'XCUITest'
options.bundle_id = 'com.github.niklaus85.OpenCommander'
options.udid = '77AA5B73-C27E-4576-BCCD-BDA04CE116F7'

driver = webdriver.Remote('http://127.0.0.1:4723', options=options)

try:
    print("App started.")
    time.sleep(2)
    
    # Check for buttons
    buttons = ["Undo", "Delete", "Rename", "Copy", "History", "ZIP"]
    for btn in buttons:
        element = driver.find_element(AppiumBy.ACCESSIBILITY_ID, btn)
        print(f"Found Button: {btn}")
        
    global_status = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "GlobalStatus")
    print(f"Initial Status: {global_status.text}")
    
    # Test ZIP with no selection
    zip_btn = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "ZIP")
    zip_btn.click()
    time.sleep(1)
    print(f"After ZIP click: {global_status.text}")
    assert "ZIP: No selection" in global_status.text
    
    # Test Copy toggle
    copy_btn = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "Copy")
    copy_btn.click()
    time.sleep(1)
    print(f"After Copy click: {global_status.text}")
    assert "Move mode active" in global_status.text
    
    # Test Undo
    undo_btn = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "Undo")
    undo_btn.click()
    time.sleep(1)
    print(f"After Undo click: {global_status.text}")
    assert "Undo executed" in global_status.text
    
    driver.get_screenshot_as_file("/Users/niklaus/.gemini/antigravity/brain/ed4cafa5-b9af-4012-bd9d-dc4e54579c2b/test_result_ios_functional.png")
    print("Screenshot saved.")
    print("All functional tests passed!")
    
finally:
    driver.quit()
