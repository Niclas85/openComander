import re

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

# Replace static button texts with L10n.get(...)
content = content.replace('miniButton(label: "Legal")', 'miniButton(label: L10n.get("legal"))')
content = content.replace('miniButton(label: "Help")', 'miniButton(label: L10n.get("help"))')
content = content.replace('miniButton(label: "Language")', 'miniButton(label: L10n.get("language"))')
content = content.replace('miniButton(label: "ZIP")', 'miniButton(label: L10n.get("zip"))')
content = content.replace('miniButton(label: "Rename")', 'miniButton(label: L10n.get("rename"))')
content = content.replace('miniButton(label: "Delete")', 'miniButton(label: L10n.get("delete"))')
content = content.replace('miniButton(label: "Undo")', 'miniButton(label: L10n.get("undo"))')
content = content.replace('miniButton(label: historyExpanded ? "Close History" : "History")', 'miniButton(label: historyExpanded ? L10n.get("close_history") : L10n.get("history"))')
content = content.replace('historyButton.setTitle(historyExpanded ? "Close History" : "History", for: .normal)', 'historyButton.setTitle(historyExpanded ? L10n.get("close_history") : L10n.get("history"), for: .normal)')
content = content.replace('miniButton(label: moveMode ? "Move" : "Copy")', 'miniButton(label: moveMode ? L10n.get("move") : L10n.get("copy"))')

# Replace toggleOperationMode texts
content = content.replace('sender.setTitle(moveMode ? "Move" : "Copy", for: .normal)', 'sender.setTitle(moveMode ? L10n.get("move") : L10n.get("copy"), for: .normal)')

# Replace Legal Dialog
old_legal = """    @objc func showLegalDialog() {
        let alert = UIAlertController(title: "Legal Information", message: "OpenCommander is open source software.\\nLicense: MIT\\nAuthor: niklaus85", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }"""
new_legal = """    @objc func showLegalDialog() {
        let alert = UIAlertController(title: L10n.get("legal_title"), message: L10n.get("legal_message"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }"""
content = content.replace(old_legal, new_legal)

# Replace Help Dialog
old_help = """    @objc func showHelpDialog() {
        let alert = UIAlertController(title: "Help", message: "Double tap a folder to enter it.\\nSelect a file and tap a button to perform an operation.\\nUse the Tree List on the left to navigate up.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }"""
new_help = """    @objc func showHelpDialog() {
        let alert = UIAlertController(title: L10n.get("help_title"), message: L10n.get("help_message"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }"""
content = content.replace(old_help, new_help)

# Replace Language Dialog
old_lang = """    @objc func showLanguageDialog() {
        let alert = UIAlertController(title: "Language", message: "Select application language", preferredStyle: .actionSheet)
        let languages = ["System Default", "English", "Deutsch", "Polski", "Italiano", "Français"]
        for lang in languages {
            alert.addAction(UIAlertAction(title: lang, style: .default, handler: { _ in
                self.updateGlobalStatus("Language changed to \\(lang)")
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.languageButton
            popover.sourceRect = self.languageButton.bounds
        }
        self.present(alert, animated: true)
    }"""
new_lang = """    @objc func showLanguageDialog() {
        let alert = UIAlertController(title: L10n.get("language"), message: nil, preferredStyle: .actionSheet)
        let languages = [("English", "en"), ("Deutsch", "de")]
        for lang in languages {
            alert.addAction(UIAlertAction(title: lang.0, style: .default, handler: { _ in
                L10n.currentLanguage = lang.1
                UserDefaults.standard.set(lang.1, forKey: "language")
                self.refreshEverything()
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.languageButton
            popover.sourceRect = self.languageButton.bounds
        }
        self.present(alert, animated: true)
    }

    func refreshEverything() {
        // Rebuild the layout to apply new localized strings
        for view in view.subviews {
            view.removeFromSuperview()
        }
        buildLayout()
        updateGlobalStatus(L10n.get("language_changed"))
    }"""
content = content.replace(old_lang, new_lang)

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
