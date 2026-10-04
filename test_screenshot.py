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
driver.save_screenshot('app_screenshot.png')
print("Screenshot saved to app_screenshot.png")
driver.quit()
