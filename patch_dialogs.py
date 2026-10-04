import re

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

# Add target actions
content = content.replace(
    'let legalButton = miniButton(label: "Legal")\n        makeLowPriorityButton(button: legalButton)',
    'let legalButton = miniButton(label: "Legal")\n        makeLowPriorityButton(button: legalButton)\n        legalButton.addTarget(self, action: #selector(showLegalDialog), for: .touchUpInside)'
)
content = content.replace(
    'let helpButton = miniButton(label: "Help")\n        makeLowPriorityButton(button: helpButton)',
    'let helpButton = miniButton(label: "Help")\n        makeLowPriorityButton(button: helpButton)\n        helpButton.addTarget(self, action: #selector(showHelpDialog), for: .touchUpInside)'
)
content = content.replace(
    'languageButton = miniButton(label: "Language")\n        makeLowPriorityButton(button: languageButton)',
    'languageButton = miniButton(label: "Language")\n        makeLowPriorityButton(button: languageButton)\n        languageButton.addTarget(self, action: #selector(showLanguageDialog), for: .touchUpInside)'
)

# Add the dialog functions at the end of the file
dialog_funcs = """
    @objc func showLegalDialog() {
        let alert = UIAlertController(title: "Legal Information", message: "OpenCommander is open source software.\\nLicense: MIT\\nAuthor: niklaus85", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }
    
    @objc func showHelpDialog() {
        let alert = UIAlertController(title: "Help", message: "Double tap a folder to enter it.\\nSelect a file and tap a button to perform an operation.\\nUse the Tree List on the left to navigate up.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }
    
    @objc func showLanguageDialog() {
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
    }
"""

content = content.replace('func rebuildHistoryPanel(msg: String) {', dialog_funcs + '\n    func rebuildHistoryPanel(msg: String) {')

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
