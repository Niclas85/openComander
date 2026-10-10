from appium import webdriver
from appium.options.common.base import AppiumOptions
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time

options = AppiumOptions()
options.load_capabilities({
    "platformName": "Android",
    "automationName": "UiAutomator2",
    "app": "/Users/niklaus/Documents/OpenCommander/app/build/outputs/apk/debug/app-debug.apk",
    "noReset": False
})

driver = webdriver.Remote("http://127.0.0.1:4723", options=options)
time.sleep(2)
driver.save_screenshot("/Users/niklaus/.gemini/antigravity/brain/ed4cafa5-b9af-4012-bd9d-dc4e54579c2b/android_screenshot.png")
driver.quit()
print("Screenshot saved to android_screenshot.png")
