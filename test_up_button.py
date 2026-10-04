from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
import time

options = XCUITestOptions()
options.platform_name = 'iOS'
options.automation_name = 'XCUITest'
options.device_name = 'iPhone 15 Pro Max'
options.bundle_id = 'com.github.niklaus85.OpenCommander'
options.no_reset = True
options.new_command_timeout = 3600

driver = webdriver.Remote('http://127.0.0.1:4723', options=options)
time.sleep(2)

print("Double tapping a directory in TreeList...")
# Try to find a folder in the tree list to expand/select, or just in FileList.
# Wait, if we are in Documents, maybe we can just create a new folder?
try:
    pathText = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeTextField')
    pathText.clear()
    pathText.send_keys("TestFolder\n")
    time.sleep(1)
    
    # Let's take a screenshot to see if we moved into TestFolder
    driver.save_screenshot('testfolder_screenshot.png')
    
    # Are there cells with ".." ?
    cells = driver.find_elements(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeCell/XCUIElementTypeStaticText')
    names = [c.text for c in cells]
    print("Cells visible:", names)

except Exception as e:
    print(f"Error: {e}")

driver.quit()
