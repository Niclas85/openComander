"""Reproduce pre-fix failures on disposable, AFC-created fixtures."""
import base64,io,json,time,zipfile
from pathlib import Path
from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from app_store_qa_test import button,select_language
out=Path('parity-evidence/iphone-usability-qa/baseline')
bundle='com.github.niklaus85.OpenCommander'
opts=XCUITestOptions().load_capabilities({'platformName':'iOS','appium:automationName':'XCUITest','appium:deviceName':'iPhone 11','appium:udid':'00008030-000E54823A91402E','appium:bundleId':bundle,'appium:noReset':True,'appium:forceAppLaunch':True,'appium:newCommandTimeout':300,'appium:webDriverAgentUrl':'http://127.0.0.1:8153'})
d=webdriver.Remote('http://127.0.0.1:4753',options=opts)
results={}
try:
 d.orientation='PORTRAIT'
 select_language(d,'Deutsch')
 d.save_screenshot(str(out/'toolbar-clipped.png'))
 win=d.get_window_rect();rects={}
 for name in ['UndoButton','DeleteButton','RenameButton','HistoryButton','ZipButton','HelpButton','OperationButton','LanguageButton','LegalButton']:
  r=button(d,name).rect
  rects[name]={'rect':r,'inside_screen':r['x']>=0 and r['x']+r['width']<=win['width']}
 results['toolbar']=rects
 select_language(d,'English')
 fixtures={
  'OpenCommanderUsabilityQA/Source/ParityFile.txt':b'OpenCommander iPhone QA content\n',
  'OpenCommanderUsabilityQA/FolderBefore/Inside.txt':b'ZIP round trip on physical iPhone\n',
  'OpenCommanderUsabilityQA/DragMe/Drag.txt':b'Copy and move integrity\n',
  'OpenCommanderUsabilityQA/AReverseSource/Reverse.txt':b'Reverse drag integrity\n',
  'OpenCommanderUsabilityQA/DropHere/.qa':b'test folder\n',
  'OpenCommanderUsabilityQA/AReverseTarget/.qa':b'test folder\n',
  'OpenCommanderEdgeQA/Empty/.seed':b'x',
  'OpenCommanderEdgeQA/One/one.txt':b'one\n',
  'OpenCommanderEdgeQA/Two/two.txt':b'two\n',
  'OpenCommanderEdgeQA/Nested/A/B/leaf.txt':b'nested\n',
 }
 for path,data in fixtures.items():d.push_file(f'@{bundle}:documents/{path}',base64.b64encode(data).decode())
 d.execute_script('mobile: deleteFile',{'remotePath':f'@{bundle}:documents/OpenCommanderEdgeQA/Empty/.seed'})
 def nav(pane,path):
  e=button(d,f'Path-{pane}');e.clear();e.send_keys(path+'\n');time.sleep(.7)
 nav(1,'/Documents/OpenCommanderEdgeQA')
 button(d,'File-1-Empty').click();button(d,'ZipButton').click();time.sleep(2)
 z=base64.b64decode(d.pull_file(f'@{bundle}:documents/OpenCommanderEdgeQA/Empty.zip'))
 (out/'empty-before.zip').write_bytes(z)
 results['empty_zip_members']=zipfile.ZipFile(io.BytesIO(z)).namelist()
 button(d,'UndoButton').click();time.sleep(1)
 nav(2,'/Documents/OpenCommanderEdgeQA')
 button(d,'File-1-One').click();button(d,'File-2-Two').click();button(d,'ZipButton').click();time.sleep(2)
 z=base64.b64decode(d.pull_file(f'@{bundle}:documents/OpenCommanderEdgeQA/OpenCommanderEdgeQA.zip'))
 (out/'both-panes-before.zip').write_bytes(z)
 results['both_panes_zip_members']=zipfile.ZipFile(io.BytesIO(z)).namelist()
 button(d,'UndoButton').click();time.sleep(1)
 nav(1,'/Documents/OpenCommanderEdgeQA/Nested')
 r=button(d,'File-1-A').rect
 d.execute_script('mobile: doubleTap',{'x':r['x']+r['width']/2,'y':r['y']+r['height']/2});time.sleep(1)
 results['double_tap_path']=button(d,'Path-1').get_attribute('value')
 d.save_screenshot(str(out/'double-tap.png'))
finally:
 (out/'reproductions.json').write_text(json.dumps(results,indent=2)+'\n')
 print(json.dumps(results,indent=2),flush=True)
 d.quit()
