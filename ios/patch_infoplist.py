import xml.etree.ElementTree as ET

tree = ET.parse('/Users/niklaus/Documents/openComander/ios/Info.plist')
root = tree.getroot()
dict_elem = root.find('dict')

key = ET.Element('key')
key.text = 'UILaunchScreen'
dict_elem.append(key)

inner_dict = ET.Element('dict')
dict_elem.append(inner_dict)

tree.write('/Users/niklaus/Documents/openComander/ios/Info.plist')
