import re

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

# Add code to create dummy files in Documents
dummy_code = """
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let rootUrl = paths[0]
        
        // --- ADD DUMMY DATA FOR TESTING ---
        let fm = FileManager.default
        let sampleFolder = rootUrl.appendingPathComponent("SampleFolder")
        let sampleFile = rootUrl.appendingPathComponent("SampleFile.txt")
        if !fm.fileExists(atPath: sampleFolder.path) {
            try? fm.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: sampleFile.path) {
            try? "Hello World".write(to: sampleFile, atomically: true, encoding: .utf8)
        }
        // ----------------------------------
        
        let root = FileEntry(url: rootUrl, parent: nil)
"""

content = re.sub(
    r'let paths = FileManager\.default\.urls\(for: \.documentDirectory, in: \.userDomainMask\)\s*let rootUrl = paths\[0\]\s*let root = FileEntry\(url: rootUrl, parent: nil\)',
    dummy_code.strip(),
    content
)

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
