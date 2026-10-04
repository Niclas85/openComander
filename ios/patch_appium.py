with open("/Users/niklaus/Documents/openComander/ios/appium_e2e_test.py", "r") as f:
    content = f.read()

content = content.replace('options.no_reset = True', 'options.no_reset = False\noptions.app = "/Users/niklaus/Library/Developer/Xcode/DerivedData/OpenCommander-begaoxsgzojkniaofsqngkbychpg/Build/Products/Debug-iphonesimulator/OpenCommander.app"')

with open("/Users/niklaus/Documents/openComander/ios/appium_e2e_test.py", "w") as f:
    f.write(content)
