import re

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

# Patch executeDeleteOperation
old_delete = """    func executeDeleteOperation(panes: [CommanderPane], sources: [FileEntry], toTrash: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var deletedCount = 0
            for source in sources {
                let url = source.url
                do {
                    if toTrash {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    } else {
                        try fm.removeItem(at: url)
                    }
                    deletedCount += 1
                } catch {
                    print("Delete error: \\(error)")
                }
            }"""

new_delete = """    func executeDeleteOperation(panes: [CommanderPane], sources: [FileEntry], toTrash: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var deletedCount = 0
            var deletedFiles: [(originalUrl: URL, backupUrl: URL)] = []
            
            let backupDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenCommanderTrash")
            try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: nil)
            
            for source in sources {
                let url = source.url
                do {
                    let backupUrl = backupDir.appendingPathComponent(UUID().uuidString)
                    try fm.copyItem(at: url, to: backupUrl)
                    deletedFiles.append((originalUrl: url, backupUrl: backupUrl))
                    
                    if toTrash {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    } else {
                        try fm.removeItem(at: url)
                    }
                    deletedCount += 1
                } catch {
                    print("Delete error: \\(error)")
                }
            }
            self.operationHistory.append(.delete(files: deletedFiles))"""

content = content.replace(old_delete, new_delete)

# Patch runFileOperation
old_run = """        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let targetURL = targetDirectory.url
            var successCount = 0
            for source in sources {
                let sourceURL = source.url
                let destURL = targetURL.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    if move {
                        try fm.moveItem(at: sourceURL, to: destURL)
                    } else {
                        try fm.copyItem(at: sourceURL, to: destURL)
                    }
                    successCount += 1
                } catch {
                    print("Error \\(move ? "moving" : "copying") \\(sourceURL): \\(error)")
                }
            }
            
            DispatchQueue.main.async {"""

new_run = """        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let targetURL = targetDirectory.url
            var successCount = 0
            
            var movedFiles: [(source: URL, destination: URL)] = []
            var copiedFiles: [(source: URL, destination: URL)] = []
            
            for source in sources {
                let sourceURL = source.url
                let destURL = targetURL.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    if move {
                        try fm.moveItem(at: sourceURL, to: destURL)
                        movedFiles.append((source: sourceURL, destination: destURL))
                    } else {
                        try fm.copyItem(at: sourceURL, to: destURL)
                        copiedFiles.append((source: sourceURL, destination: destURL))
                    }
                    successCount += 1
                } catch {
                    print("Error \\(move ? "moving" : "copying") \\(sourceURL): \\(error)")
                }
            }
            
            if move {
                self.operationHistory.append(.move(files: movedFiles))
            } else if !copiedFiles.isEmpty {
                self.operationHistory.append(.copy(files: copiedFiles))
            }
            
            DispatchQueue.main.async {"""

content = content.replace(old_run, new_run)

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
