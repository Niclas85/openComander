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

def check_button(name):
    try:
        btn = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, f'**/XCUIElementTypeButton[`label == "{name}"`]')
        btn.click()
        time.sleep(1)
        status = driver.find_element(AppiumBy.ACCESSIBILITY_ID, 'GlobalStatus').text
        print(f"Clicked {name} -> Status: {status}")
    except Exception as e:
        print(f"Error clicking {name}: {e}")

check_button("ZIP")
check_button("Copy")
check_button("Rename")
check_button("Delete")

driver.quit()
