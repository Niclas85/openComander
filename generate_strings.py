import xml.etree.ElementTree as ET
import glob
import os
import re

langs = {'default': 'en'}
for path in glob.glob('/Users/niklaus/Documents/OpenCommander/app/src/main/res/values-*'):
    lang = os.path.basename(path).split('-')[1]
    langs[lang] = lang

def parse_strings(filepath):
    if not os.path.exists(filepath): return {}
    tree = ET.parse(filepath)
    root = tree.getroot()
    res = {}
    for child in root:
        if 'name' in child.attrib:
            val = child.text if child.text else ""
            val = val.replace('"', '\\"').replace('\n', '\\n')
            # Replace Android formats %1$s -> %@, %1$d -> %d
            val = re.sub(r'%\d\$s', '%@', val)
            val = re.sub(r'%\d\$d', '%d', val)
            res[child.attrib['name']] = val
    return res

all_strings = {}
for lang_key, lang_code in langs.items():
    if lang_key == 'default':
        filepath = '/Users/niklaus/Documents/OpenCommander/app/src/main/res/values/strings.xml'
    else:
        filepath = f'/Users/niklaus/Documents/OpenCommander/app/src/main/res/values-{lang_key}/strings.xml'
    all_strings[lang_code] = parse_strings(filepath)

print("import Foundation\n")
print("class L10n {")
print('    static var currentLanguage = UserDefaults.standard.string(forKey: "language") ?? "en"\n')
print("    static let strings: [String: [String: String]] = [")
for lang, strings in all_strings.items():
    print(f'        "{lang}": [')
    for key, value in strings.items():
        if not value: continue
        val_clean = value.replace('\n', '\\n').replace('"', '\\"')
        print(f'            "{key}": "{val_clean}",')
    print("        ],")
print("    ]")
print("""
    static func get(_ key: String, _ args: CVarArg...) -> String {
        let dict = strings[currentLanguage] ?? strings["en"] ?? [:]
        let format = dict[key] ?? strings["en"]?[key] ?? key
        if args.isEmpty {
            return format
        }
        return String(format: format, arguments: args)
    }
}""")
