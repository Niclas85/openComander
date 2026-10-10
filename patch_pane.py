import re

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/Pane.swift", "r") as f:
    content = f.read()

func_code = """
    @objc func navigateUp() {
        if let parent = currentDirectory.parent {
            openDirectory(parent)
        } else {
            viewController?.updateGlobalStatus("Already at root")
        }
    }
"""

content = content.replace("func openDirectory(_ directory: FileEntry) {", func_code + "\n    func openDirectory(_ directory: FileEntry) {")

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/Pane.swift", "w") as f:
    f.write(content)
