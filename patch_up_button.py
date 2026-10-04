import re

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/Pane.swift", "r") as f:
    content = f.read()

content = content.replace('upButton.setTitle("⬆ Up", for: .normal)', 'upButton.setTitle(" ⬆ ", for: .normal)')
content = content.replace('pathText.widthAnchor.constraint(equalTo: pathRow.widthAnchor, multiplier: 0.45).isActive = true', 'pathText.widthAnchor.constraint(equalTo: pathRow.widthAnchor, multiplier: 0.58, constant: -dp(3)).isActive = true')

with open("/Users/niklaus/Documents/openComander/ios/OpenCommander/Pane.swift", "w") as f:
    f.write(content)
