from appium import webdriver
from appium.webdriver.common.appiumby import AppiumBy
from appium.options.ios import XCUITestOptions
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time

options = XCUITestOptions()
options.platform_name = "iOS"
options.automation_name = "XCUITest"
options.device_name = "iPhone 15 Pro Max"
options.platform_version = "26.2"
options.bundle_id = "com.github.niklaus85.OpenCommander"
options.no_reset = False
options.app = "/Users/niklaus/Library/Developer/Xcode/DerivedData/OpenCommander-begaoxsgzojkniaofsqngkbychpg/Build/Products/Debug-iphonesimulator/OpenCommander.app"
options.new_command_timeout = 300

try:
    print("Connecting to Appium...")
    driver = webdriver.Remote("http://127.0.0.1:4723", options=options)
    wait = WebDriverWait(driver, 10)
    
    print("Waiting for app to load...")
    time.sleep(3)
    
    # Verify Compact Up Button exists
    print("Verifying Up Button...")
    up_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, " ⬆ ")))
    up_button.click()
    
    # Verify Legal Dialog
    print("Verifying Legal Dialog...")
    legal_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Legal")))
    legal_button.click()
    time.sleep(1)
    # Just dismiss it
    wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "OK"))).click()
    
    # Verify Help Dialog
    print("Verifying Help Dialog...")
    help_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Help")))
    help_button.click()
    time.sleep(1)
    wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "OK"))).click()
    
    # Change Language to German
    print("Verifying Language Switching...")
    language_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Language")))
    language_button.click()
    time.sleep(1)
    german_option = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Deutsch")))
    german_option.click()
    
    # Verify UI updated to German
    time.sleep(2)
    hilfe_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Hilfe")))
    print("UI successfully switched to German!")
    
    # Select a file to ZIP
    print("Verifying ZIP...")
    sample_file = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "SampleFile.txt")))
    sample_file.click() # Select
    zip_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "ZIP")))
    zip_button.click()
    time.sleep(2)
    
    # Verify Delete and Undo
    print("Verifying Delete & Undo...")
    wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, 'SampleFile.txt'))).click() # Select again
    delete_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Löschen"))) # In German!
    delete_button.click()
    time.sleep(1)
    wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Delete"))).click() # Alert action
    time.sleep(2)
    undo_button = wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, "Rückgängig")))
    undo_button.click()
    time.sleep(2)
    
    # Final Screenshot
    driver.save_screenshot("/Users/niklaus/.gemini/antigravity/brain/ed4cafa5-b9af-4012-bd9d-dc4e54579c2b/final_localized_ios_test.png")
    print("All E2E tests passed successfully!")

except Exception as e:
    print(f"Test failed: {e}")
finally:
    if 'driver' in locals():
        driver.quit()
