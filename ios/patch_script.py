with open("/Users/niklaus/Documents/openComander/ios/appium_e2e_test.py", "r") as f:
    content = f.read()

content = content.replace("sample_file.click() # Select again", "wait.until(EC.presence_of_element_located((AppiumBy.ACCESSIBILITY_ID, 'SampleFile.txt'))).click() # Select again")

with open("/Users/niklaus/Documents/openComander/ios/appium_e2e_test.py", "w") as f:
    f.write(content)
