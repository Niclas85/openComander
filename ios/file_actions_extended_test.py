"""Visible drag/drop edge cases; operates only on OpenCommanderDropQA."""
import base64
import io
import json
import os
from pathlib import Path
import time
import zipfile
from appium import webdriver
from appium.options.ios import XCUITestOptions
from selenium.webdriver.support.ui import WebDriverWait
from appium.webdriver.common.appiumby import AppiumBy
from app_store_qa_test import button, select_language

BUNDLE='com.github.niklaus85.OpenCommander'
ROOT='OpenCommanderDropQA'
OUT=Path(os.environ['QA_EVIDENCE'])
DATA={'Source/guarded-copy.txt':b'Drag background and tree integrity\n',
      'Target/existing.txt':b'Keep unrelated target\n', 'TreeTarget/Destination/.qa':b'folder\n',
      'MoveSource/Folder/item.txt':b'Moving source bytes\n',
      'MoveTarget/Folder/item.txt':b'Previous target bytes\n',
      'MultiSource/Grüße.txt':'Grüße\n'.encode(),'MultiSource/zero.txt':b'',
      'MultiTarget/.qa':b'empty target\n'}
buf=io.BytesIO()
with zipfile.ZipFile(buf,'w') as z:
    z.writestr(zipfile.ZipInfo('inside.txt',date_time=(2026,1,1,0,0,0)),b'Archive stays unchanged\n')
DATA['readonly.zip']=buf.getvalue()

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    caps={
        'platformName':'iOS','appium:automationName':'XCUITest','appium:deviceName':os.environ.get('IOS_DEVICE_NAME','iPhone 11'),
        'appium:platformVersion':os.environ.get('IOS_VERSION','26.6.1'),'appium:udid':os.environ['IOS_UDID'],
        'appium:bundleId':BUNDLE,'appium:noReset':True,'appium:forceAppLaunch':True,
        'appium:newCommandTimeout':300}
    if os.environ.get('WDA_URL'):
        caps['appium:webDriverAgentUrl']=os.environ['WDA_URL']
    else:
        caps['appium:usePreinstalledWDA']=True
        caps['appium:wdaLocalPort']=int(os.environ.get('WDA_LOCAL_PORT','8159'))
    d=webdriver.Remote(os.environ['APPIUM_SERVER'],options=XCUITestOptions().load_capabilities(caps))
    checks=[]
    def passed(label):
        checks.append(label);(OUT/'checks.json').write_text(json.dumps(checks,indent=2)+'\n');print('PASS '+label,flush=True)
    def tap(name):
        r=button(d,name).rect
        d.execute_script('mobile: tap',{'x':r['x']+r['width']/2,'y':r['y']+r['height']/2});time.sleep(.2)
    def read(path):
        if os.environ.get('SIM_DATA_CONTAINER'):
            return (Path(os.environ['SIM_DATA_CONTAINER'])/'Documents'/ROOT/path).read_bytes()
        return base64.b64decode(d.pull_file(f'@{BUNDLE}:documents/{ROOT}/{path}'))
    def missing(path):
        try:read(path)
        except Exception as e:assert isinstance(e,FileNotFoundError) or 'OBJECT_NOT_FOUND' in str(e) or 'does not exist on the device' in str(e),str(e)
        else:raise AssertionError('unexpected file: '+path)
    def status():return button(d,'GlobalStatus').text.lower()
    def wait(text):WebDriverWait(d,20).until(lambda _:text in status())
    def nav(pane,path):
        f=button(d,f'Path-{pane}');f.clear();f.send_keys(path+'\n');time.sleep(.4)
    def own(pane,sub):nav(pane,f'/Documents/{ROOT}/'+sub)
    def mode(name):
        if button(d,'OperationButton').get_attribute('label') != name: tap('OperationButton')
        assert button(d,'OperationButton').get_attribute('label')==name
    def drag(source,target=None,pane=2):
        a=button(d,source).rect
        if target:
            r=button(d,target).rect;x=r['x']+r['width']/2;y=r['y']+r['height']/2
        else:
            r=button(d,f'FileList-{pane}').rect;x=r['x']+r['width']/2;y=r['y']+r['height']-18
        d.execute_script('mobile: dragFromToForDuration',{'duration':1.5,
            'fromX':a['x']+a['width']/2,'fromY':a['y']+a['height']/2,'toX':x,'toY':y})
        time.sleep(1)
    def undo():tap('UndoButton');wait('undone')
    try:
        d.update_settings({'waitForIdleTimeout':.5,'animationCoolOffTimeout':.2})
        d.orientation='PORTRAIT';select_language(d,'English')
        # Fixture seeding happens in the separate preparation script, which refuses
        # to overwrite any existing fixture roots.
        for p,v in DATA.items():assert read(p)==v,p
        own(1,'Source');own(2,'Target')
        drag('File-1-guarded-copy.txt');wait('copied')
        assert read('Target/guarded-copy.txt')==DATA['Source/guarded-copy.txt']
        assert read('Target/existing.txt')==DATA['Target/existing.txt']
        d.save_screenshot(str(OUT/'background-drop.png'));undo();missing('Target/guarded-copy.txt')
        passed('Drop below the last row copies into current directory without crash; Undo preserves unrelated files')

        own(1,'Source');own(2,'TreeTarget')
        drag('File-1-guarded-copy.txt','Tree-2-Destination');wait('copied')
        assert read('TreeTarget/Destination/guarded-copy.txt')==DATA['Source/guarded-copy.txt']
        undo();missing('TreeTarget/Destination/guarded-copy.txt')
        passed('Drop on directory-tree destination copies to that folder and is undoable')

        own(1,'Source');own(2,'Source')
        drag('File-1-guarded-copy.txt');wait('copied')
        assert '0 ' in status(), status()
        assert read('Source/guarded-copy.txt')==DATA['Source/guarded-copy.txt']
        missing('Source/guarded-copy (2).txt')
        passed('Copy into same directory is a safe no-op without duplicate or conflict prompt')
        mode('Move');drag('File-1-guarded-copy.txt');wait('moved')
        assert '0 ' in status(), status()
        assert read('Source/guarded-copy.txt')==DATA['Source/guarded-copy.txt']
        missing('Source/guarded-copy (2).txt')
        passed('Move into same directory is a safe no-op with original content intact')

        own(1,'MoveSource');own(2,'MoveTarget')
        drag('File-1-Folder');tap('Cancel')
        assert read('MoveSource/Folder/item.txt')==DATA['MoveSource/Folder/item.txt']
        assert read('MoveTarget/Folder/item.txt')==DATA['MoveTarget/Folder/item.txt']
        passed('Move conflict cancel preserves source and previous destination')
        drag('File-1-Folder');tap('Replace');wait('moved')
        missing('MoveSource/Folder/item.txt');assert read('MoveTarget/Folder/item.txt')==DATA['MoveSource/Folder/item.txt']
        undo();assert read('MoveSource/Folder/item.txt')==DATA['MoveSource/Folder/item.txt']
        assert read('MoveTarget/Folder/item.txt')==DATA['MoveTarget/Folder/item.txt']
        passed('Move conflict replace and Undo restore both original source and previous destination bytes')
        drag('File-1-Folder');tap('Keep');wait('moved')
        missing('MoveSource/Folder/item.txt');assert read('MoveTarget/Folder (2)/item.txt')==DATA['MoveSource/Folder/item.txt']
        assert read('MoveTarget/Folder/item.txt')==DATA['MoveTarget/Folder/item.txt']
        undo();missing('MoveTarget/Folder (2)/item.txt')
        assert read('MoveSource/Folder/item.txt')==DATA['MoveSource/Folder/item.txt']
        passed('Move conflict keep uses a separate name; Undo restores source without changing existing folder')

        own(1,'MultiSource');own(2,'MultiTarget')
        tap('File-1-Grüße.txt');tap('File-1-zero.txt');drag('File-1-Grüße.txt');wait('moved')
        for name in ['Grüße.txt','zero.txt']:
            missing('MultiSource/'+name);assert read('MultiTarget/'+name)==DATA['MultiSource/'+name]
        undo()
        for name in ['Grüße.txt','zero.txt']:
            missing('MultiTarget/'+name);assert read('MultiSource/'+name)==DATA['MultiSource/'+name]
        passed('Multiple-selection move handles Unicode and empty files; Undo restores both exactly')

        mode('Copy');own(1,'Source');own(2,'readonly.zip')
        drag('File-1-guarded-copy.txt');wait('not writable')
        assert read('readonly.zip')==DATA['readonly.zip'] and read('Source/guarded-copy.txt')==DATA['Source/guarded-copy.txt']
        passed('Drop into read-only ZIP is rejected and original bytes remain unchanged')

        if os.environ.get('QA_SIMULATOR') == '1':
            # Simulator host filesystem permissions do not prove iOS sandbox behavior.
            for p,v in DATA.items():assert read(p)==v,p
            select_language(d,'Deutsch');d.save_screenshot(str(OUT/'final.png'))
            passed('All original simulator fixture contents remain byte-identical; protected-container case reserved for physical iPhone')
            return
        nav(2,'/Documents');tap('Up-2');own(1,'Source')
        drag('File-1-guarded-copy.txt')
        WebDriverWait(d,20).until(lambda _: 'not writable' in status() or 'error' in status())
        assert read('Source/guarded-copy.txt')==DATA['Source/guarded-copy.txt']
        passed('Protected iOS container target is rejected without damaging the source')
        for p,v in DATA.items():assert read(p)==v,p
        select_language(d,'Deutsch');d.save_screenshot(str(OUT/'final.png'))
        passed('All original edge-case fixture contents remain byte-identical')
    except Exception:
        try:d.save_screenshot(str(OUT/'failure.png'));(OUT/'failure.xml').write_text(d.page_source)
        finally:raise
    finally:d.quit()

if __name__=='__main__':main()
