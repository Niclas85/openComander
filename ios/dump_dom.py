from appium import webdriver
from appium.options.ios import XCUITestOptions
import time

options = XCUITestOptions()
options.platform_name = "iOS"
options.automation_name = "XCUITest"
options.device_name = "iPhone 15 Pro Max"
options.platform_version = "26.2"
options.bundle_id = "com.github.niklaus85.OpenCommander"
options.no_reset = True

driver = webdriver.Remote("http://127.0.0.1:4723", options=options)
time.sleep(3)
with open("dom.xml", "w") as f:
    f.write(driver.page_source)
driver.quit()
