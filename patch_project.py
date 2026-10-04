import re

with open("/Users/niklaus/Documents/openComander/ios/project.yml", "r") as f:
    content = f.read()

packages_block = """packages:
  ZIPFoundation:
    url: https://github.com/weichsel/ZIPFoundation.git
    from: 0.9.19

"""
if "packages:" not in content:
    content = packages_block + content

if "dependencies:" not in content:
    content = content.replace(
        "    sources:\n      - path: OpenCommander",
        "    dependencies:\n      - package: ZIPFoundation\n    sources:\n      - path: OpenCommander"
    )

with open("/Users/niklaus/Documents/openComander/ios/project.yml", "w") as f:
    f.write(content)
