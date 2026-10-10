import re

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

# Add import
if "import ZIPFoundation" not in content:
    content = content.replace("import UIKit", "import UIKit\nimport ZIPFoundation")

# Replace createZipFromCurrentSelection
old_zip = """    @objc func createZipFromCurrentSelection() {
        let panes = selectedPanes()
        let sources = selectedEntriesFromPanes(panes)
        if sources.isEmpty {
            updateGlobalStatus("ZIP: No selection")
            return
        }
        updateGlobalStatus("ZIP: Compressed \\((sources.count)) item(s)")
        for pane in panes {
            pane.selectedKeys.removeAll()
            pane.refreshFiles()
        }
    }"""

new_zip = """    @objc func createZipFromCurrentSelection() {
        let panes = selectedPanes()
        let sources = selectedEntriesFromPanes(panes)
        if sources.isEmpty {
            updateGlobalStatus("ZIP: No selection")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let parentDir = sources.first!.url.deletingLastPathComponent()
            let archiveUrl = parentDir.appendingPathComponent("Archive.zip")
            
            do {
                if fm.fileExists(atPath: archiveUrl.path) {
                    try fm.removeItem(at: archiveUrl)
                }
                
                guard let archive = Archive(url: archiveUrl, accessMode: .create) else {
                    DispatchQueue.main.async { self.updateGlobalStatus("Failed to create ZIP") }
                    return
                }
                
                for source in sources {
                    let sourceUrl = source.url
                    let isDir = source.isDirectoryLike()
                    
                    if isDir {
                        let dirEnumerator = fm.enumerator(at: sourceUrl, includingPropertiesForKeys: nil)
                        while let file = dirEnumerator?.nextObject() as? URL {
                            let path = file.path.replacingOccurrences(of: sourceUrl.deletingLastPathComponent().path + "/", with: "")
                            try archive.addEntry(with: path, relativeTo: sourceUrl.deletingLastPathComponent())
                        }
                    } else {
                        try archive.addEntry(with: sourceUrl.lastPathComponent, relativeTo: sourceUrl.deletingLastPathComponent())
                    }
                }
                
                DispatchQueue.main.async {
                    self.updateGlobalStatus("ZIP: Created Archive.zip")
                    for pane in panes {
                        pane.selectedKeys.removeAll()
                        pane.refreshFiles()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateGlobalStatus("ZIP Error: \\(error.localizedDescription)")
                }
            }
        }
    }"""

content = content.replace(old_zip, new_zip)

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
