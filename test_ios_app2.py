from appium import webdriver
from appium.webdriver.common.appiumby import AppiumBy
from appium.options.ios import XCUITestOptions
import time

options = XCUITestOptions()
options.platform_name = 'iOS'
options.device_name = 'iPhone 15 Pro Max'
options.automation_name = 'XCUITest'
options.bundle_id = 'com.github.niklaus85.OpenCommander'
options.no_reset = True

driver = webdriver.Remote('http://127.0.0.1:4723', options=options)
driver.implicitly_wait(5)

try:
    print("Waiting for app to load...")
    time.sleep(2)
    
    # 4. Double-click SampleFolder to enter it
    print("Double clicking SampleFolder...")
    sample_folder = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeCell/XCUIElementTypeStaticText[`label == "SampleFolder"`]')
    driver.execute_script("mobile: doubleTap", {"element": sample_folder.id})
    time.sleep(2)
    
    # Check that we are inside SampleFolder by checking the path text
    path_text = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeTextField')
    print("Path text is:", path_text.text)
    
    driver.save_screenshot("/Users/niklaus/.gemini/antigravity/brain/ed4cafa5-b9af-4012-bd9d-dc4e54579c2b/ios_test_result.png")
    
    # 5. Navigate UP using TreeList
    print("Navigating UP using TreeList...")
    documents_node = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeCell/XCUIElementTypeStaticText[`label == "Documents"`]')
    documents_node.click()
    time.sleep(2)
    
    path_text_up = driver.find_element(AppiumBy.IOS_CLASS_CHAIN, '**/XCUIElementTypeTextField')
    print("Path text after going UP:", path_text_up.text)
    
    driver.save_screenshot("/Users/niklaus/.gemini/antigravity/brain/ed4cafa5-b9af-4012-bd9d-dc4e54579c2b/ios_test_result_up.png")

finally:
    driver.quit()
    print("Session closed.")

