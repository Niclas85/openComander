from appium import webdriver
from appium.webdriver.common.appiumby import AppiumBy
from appium.options.ios import XCUITestOptions
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time
import os
import xml.dom.minidom

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
    
    source = driver.page_source
    dom = xml.dom.minidom.parseString(source)
    print("Looking for buttons...")
    
    if "⬆ Up" in source:
        print("Found Up button in source!")
    else:
        print("Up button NOT found.")
        
    if "Legal" in source:
        print("Found Legal button in source!")
    else:
        print("Legal button NOT found.")

    driver.save_screenshot("/Users/niklaus/.gemini/antigravity/brain/ed4cafa5-b9af-4012-bd9d-dc4e54579c2b/real_final_ios_test2.png")
    print("Screenshot saved to real_final_ios_test2.png")
    
except Exception as e:
    print(f"Error during test: {e}")
finally:
    if 'driver' in locals():
        driver.quit()
