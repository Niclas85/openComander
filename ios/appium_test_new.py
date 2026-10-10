from appium import webdriver
from appium.webdriver.common.appiumby import AppiumBy
from appium.options.ios import XCUITestOptions
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time
import os

options = XCUITestOptions()
options.platform_name = "iOS"
options.automation_name = "XCUITest"
options.device_name = "iPhone 15 Pro Max"
options.platform_version = "26.2"
options.bundle_id = "com.github.niklaus85.OpenCommander"
options.no_reset = True
options.new_command_timeout = 300

try:
    print("Connecting to Appium...")
    driver = webdriver.Remote("http://127.0.0.1:4723", options=options)
    wait = WebDriverWait(driver, 10)
    
    print("Waiting for app to load...")
    time.sleep(3)
    
    # 1. Test Up Button
    print("Testing Up Button...")
    up_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "⬆ Up")))
    up_button.click()
    time.sleep(1)
    
    # 2. Test Help Button
    print("Testing Help Button...")
    help_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Help")))
    help_button.click()
    time.sleep(1)
    
    # Dismiss Help Alert
    ok_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "OK")))
    ok_button.click()
    time.sleep(1)
    
    # 3. Test Legal Button
    print("Testing Legal Button...")
    legal_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Legal")))
    legal_button.click()
    time.sleep(1)
    
    # Dismiss Legal Alert
    ok_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "OK")))
    ok_button.click()
    time.sleep(1)
    
    # 4. Take screenshot of final state
    driver.save_screenshot("/Users/niklaus/Documents/OpenCommander/ios/final_test_result.png")
    print("Screenshot saved to final_test_result.png")
    
    print("All tests passed successfully.")
except Exception as e:
    print(f"Error during test: {e}")
finally:
    if 'driver' in locals():
        driver.quit()
