"""Seed isolated fixtures without overwriting existing directories or user files."""
import base64
import json
import os
from pathlib import Path
import subprocess
from appium import webdriver
from appium.options.ios import XCUITestOptions
from file_actions_extended_test import DATA, ROOT

OUT=Path(os.environ['QA_EVIDENCE'])
BUNDLE='com.github.niklaus85.OpenCommander'
DEVICE=os.environ['IOS_UDID']
STANDARD={
 'Source/ParityFile.txt':b'OpenCommander iPhone QA content\n',
 'FolderBefore/Inside.txt':b'ZIP round trip on physical iPhone\n',
 'DragMe/Drag.txt':b'Copy and move integrity\n',
 'AReverseSource/Reverse.txt':b'Reverse drag integrity\n',
 'DropHere/.qa':b'test folder\n','AReverseTarget/.qa':b'test folder\n'}
EDGE={'Nested/A/B/leaf.txt':b'nested navigation\n','One/one.txt':b'one\n','Two/two.txt':b'two\n'}
FIXTURES={'OpenCommanderUsabilityQA':STANDARD,'OpenCommanderEdgeQA':EDGE,ROOT:DATA}

def main():
 OUT.mkdir(parents=True,exist_ok=True)
 subprocess.run(['xcrun','devicectl','device','info','files','--device',DEVICE,'--domain-type','appDataContainer',
  '--domain-identifier',BUNDLE,'--subdirectory','Documents','--no-recurse','--json-output',str(OUT/'documents-before.json')],check=True,capture_output=True)
 listing=(OUT/'documents-before.json').read_text()
 assert all(root not in listing for root in FIXTURES), 'An existing test directory must be reviewed before proceeding'
 caps={'platformName':'iOS','appium:automationName':'XCUITest','appium:deviceName':'iPhone 11','appium:platformVersion':'26.6.1',
  'appium:udid':DEVICE,'appium:bundleId':BUNDLE,'appium:noReset':True,'appium:webDriverAgentUrl':os.environ['WDA_URL']}
 d=webdriver.Remote(os.environ['APPIUM_SERVER'],options=XCUITestOptions().load_capabilities(caps))
 try:
  for root,files in FIXTURES.items():
   for path,data in files.items():d.push_file(f'@{BUNDLE}:documents/{root}/{path}',base64.b64encode(data).decode())
  (OUT/'fixture-originals.json').write_text(json.dumps({root:{p:base64.b64encode(b).decode() for p,b in files.items()} for root,files in FIXTURES.items()},indent=2)+'\n')
 finally:d.quit()
 print('Prepared isolated fixture roots; existing Documents items unchanged')

if __name__=='__main__':main()
