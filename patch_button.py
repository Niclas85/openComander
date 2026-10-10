with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "r") as f:
    content = f.read()

content = content.replace(
    'button.translatesAutoresizingMaskIntoConstraints = false\n        button.heightAnchor.constraint(greaterThanOrEqualToConstant: dp(36)).isActive = true\n        return button',
    'button.translatesAutoresizingMaskIntoConstraints = false\n        button.heightAnchor.constraint(greaterThanOrEqualToConstant: dp(36)).isActive = true\n        button.setContentCompressionResistancePriority(.required, for: .horizontal)\n        return button'
)

with open("/Users/niklaus/Documents/OpenCommander/ios/OpenCommander/ViewController.swift", "w") as f:
    f.write(content)
