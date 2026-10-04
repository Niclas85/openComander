import time
import os
from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy

app_path = '/Users/niklaus/Library/Developer/Xcode/DerivedData/OpenCommander-begaoxsgzojkniaofsqngkbychpg/Build/Products/Debug-iphonesimulator/OpenCommander.app'

options = XCUITestOptions()
options.platform_name = 'iOS'
options.device_name = 'iPhone 15 Pro Max'
options.udid = '77AA5B73-C27E-4576-BCCD-BDA04CE116F7'
options.automation_name = 'XCUITest'
options.app = app_path

print(f"Connecting to Appium and installing app from: {app_path}")

driver = webdriver.Remote('http://127.0.0.1:4723', options=options)

try:
    print("App launched successfully. Waiting for UI elements...")
    time.sleep(3)
    
    # Try to find the top bar title
    try:
        title = driver.find_element(by=AppiumBy.ACCESSIBILITY_ID, value="OpenCommander")
        print("Test Passed: Found 'OpenCommander' title in UI.")
    except Exception:
        print("Title 'OpenCommander' not found by accessibility ID. Trying XPATH...")
        title = driver.find_element(by=AppiumBy.XPATH, value="//XCUIElementTypeStaticText[@name='OpenCommander']")
    try:
        driver.find_element(by=AppiumBy.XPATH, value="//XCUIElementTypeStaticText[@name='TREE']")
        print("Test Passed: Found 'TREE' column.")
        driver.find_element(by=AppiumBy.XPATH, value="//XCUIElementTypeStaticText[@name='FILES']")
        print("Test Passed: Found 'FILES' column.")
    except Exception as e:
        print(f"Columns not found: {e}")
        pass
        
    time.sleep(2)
    driver.save_screenshot('test_result.png')
    print("Screenshot saved to test_result.png")
    
except Exception as e:
    print(f"Test Failed: {e}")
finally:
    driver.quit()
    print("Test finished.")
