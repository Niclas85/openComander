import re

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

# Add OperationType enum and operationHistory var
if "enum OperationType {" not in content:
    enum_code = """
enum OperationType {
    case delete(files: [(originalUrl: URL, backupUrl: URL)])
    case move(files: [(source: URL, destination: URL)])
    case copy(files: [(source: URL, destination: URL)])
    case rename(originalUrl: URL, newUrl: URL)
}

class ViewController: UIViewController {
    var operationHistory: [OperationType] = []
"""
    content = content.replace("class ViewController: UIViewController {", enum_code)

# Replace executeUndo
old_undo = """    @objc func undoLastOperation() {
        updateGlobalStatus("Undo executed")
    }"""

new_undo = """    @objc func undoLastOperation() {
        guard let lastOp = operationHistory.popLast() else {
            updateGlobalStatus("No history to undo")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            do {
                switch lastOp {
                case .delete(let files):
                    for file in files {
                        try fm.moveItem(at: file.backupUrl, to: file.originalUrl)
                    }
                case .move(let files):
                    for file in files {
                        try fm.moveItem(at: file.destination, to: file.source)
                    }
                case .copy(let files):
                    for file in files {
                        try fm.removeItem(at: file.destination)
                    }
                case .rename(let originalUrl, let newUrl):
                    try fm.moveItem(at: newUrl, to: originalUrl)
                }
                
                DispatchQueue.main.async {
                    self.updateGlobalStatus("Undo successful")
                    self.leftPane.refreshFiles()
                    self.rightPane.refreshFiles()
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateGlobalStatus("Undo failed: \\(error.localizedDescription)")
                }
            }
        }
    }"""

content = content.replace(old_undo, new_undo)

# Patch rename to push to history
rename_regex = r"(try fm\.moveItem\(at: url, to: newUrl\))"
content = re.sub(rename_regex, r"\1\n                self.operationHistory.append(.rename(originalUrl: url, newUrl: newUrl))", content)

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
