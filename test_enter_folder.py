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

print("Opening TestFolder via path bar...")
try:
    pathText = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeTextField')
    pathText.clear()
    
    import subprocess
    data_dir = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', 'booted', 'com.github.niklaus85.OpenCommander', 'data']).decode().strip()
    path_to_test = f"{data_dir}/Documents/TestFolder\n"
    pathText.send_keys(path_to_test)
    time.sleep(1)
    
    driver.save_screenshot('entered_testfolder.png')
    
    cells = driver.find_elements(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeCell/XCUIElementTypeStaticText')
    names = [c.text for c in cells]
    print("Cells visible:", names)

except Exception as e:
    print(f"Error: {e}")

driver.quit()
