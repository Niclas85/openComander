"""Physical-device ZIP regression: protected parent, fallback, contents and undo.

Requires Documents to be empty at the start. Creates only ZIPDestinationQA and
Documents.zip / Documents (2).zip; removes only those test-created paths.
"""
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import time
import zipfile

from appium import webdriver
from appium.options.ios import XCUITestOptions
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait
from app_store_qa_test import button, select_language

OUT = Path('parity-evidence/iphone-zip-followup')
BUNDLE = 'com.github.niklaus85.OpenCommander'
DEVICE = '00008030-000E54823A91402E'
ROOT = 'ZIPDestinationQA'
checks = []

def main():
    subprocess.run(['xcrun','devicectl','device','info','files','--device',DEVICE,'--domain-type','appDataContainer',
                    '--domain-identifier',BUNDLE,'--subdirectory','Documents','--no-recurse','--json-output',str(OUT/'test-start.json')],check=True,capture_output=True)
    assert json.loads((OUT/'test-start.json').read_text())['result']['files'] == [], 'Requires empty Documents; do not overwrite user data'
    caps={'platformName':'iOS','appium:automationName':'XCUITest','appium:deviceName':'iPhone 11',
          'appium:platformVersion':'26.6.1','appium:udid':DEVICE,'appium:noReset':True,
          'appium:bundleId':BUNDLE,'appium:forceAppLaunch':True,'appium:webDriverAgentUrl':'http://127.0.0.1:8153'}
    d=webdriver.Remote('http://127.0.0.1:4753',options=XCUITestOptions().load_capabilities(caps))
    d.update_settings({'waitForIdleTimeout':.5,'animationCoolOffTimeout':.2})
    def tap(name):
        r=button(d,name).rect
        d.execute_script('mobile: tap',{'x':r['x']+r['width']/2,'y':r['y']+r['height']/2})
        time.sleep(.2)
    def status(): return button(d,'GlobalStatus').text
    def wait_status(text):
        WebDriverWait(d,30).until(lambda _: text.lower() in status().lower())
    def passed(text):
        checks.append(text);(OUT/'checks.json').write_text(json.dumps(checks,indent=2)+'\n');print('PASS '+text,flush=True)
    def nav(path):
        f=button(d,'Path-1');f.clear();f.send_keys(path+'\n');time.sleep(.3)
    def pull(path): return base64.b64decode(d.pull_file(f'@{BUNDLE}:documents/{path}'))
    def push(path,data): d.push_file(f'@{BUNDLE}:documents/{path}',base64.b64encode(data).decode())
    def archive(path):
        raw=pull(path);(OUT/('verified-'+path.replace('/','_'))).write_bytes(raw)
        with zipfile.ZipFile(io.BytesIO(raw)) as z:
            assert z.testzip() is None
            return {n:z.read(n) for n in z.namelist()}
    def undo(path):
        tap('UndoButton');wait_status('undone')
        try: pull(path)
        except Exception as e:
            assert 'OBJECT_NOT_FOUND' in str(e) or 'does not exist on the device' in str(e),str(e)
        else: raise AssertionError('Undo left ZIP: '+path)
    try:
        d.orientation='PORTRAIT';select_language(d,'English')
        tap('Up-1');tap('File-1-Documents');tap('ZipButton');wait_status('ZIP created')
        assert status()=='ZIP created: /Documents/Documents.zip',status()
        assert button(d,'Path-1').get_attribute('value')=='/Documents'
        assert archive('Documents.zip')=={'Documents/':b''}
        d.save_screenshot(str(OUT/'documents-zip-success.png'))
        passed('Empty Documents ZIP succeeds despite protected parent; archive visible inside Documents; no self inclusion')
        undo('Documents.zip');passed('Undo fallback archive removes only the new ZIP')

        push(ROOT+'/inside/Grüße.txt','Grüße\n'.encode());push(ROOT+'/empty/.seed',b'x');push(ROOT+'/.hidden',b'hidden\n')
        d.execute_script('mobile: deleteFile',{'remotePath':f'@{BUNDLE}:documents/{ROOT}/empty/.seed'})
        expected={ROOT+'/':b'',ROOT+'/inside/':b'',ROOT+'/inside/Grüße.txt':'Grüße\n'.encode(),ROOT+'/empty/':b'',ROOT+'/.hidden':b'hidden\n'}
        nav('/Documents');tap('File-1-'+ROOT);tap('ZipButton');wait_status('ZIP created')
        assert archive(ROOT+'.zip')==expected
        assert status()=='ZIP created: '+ROOT+'.zip',status()
        undo(ROOT+'.zip');passed('Ordinary folder still ZIPs beside source; nested, empty, hidden and Unicode contents match exactly; Undo works')

        nav('/Documents/'+ROOT);tap('File-1-inside');tap('File-1-empty');tap('ZipButton');wait_status('ZIP created')
        assert archive(ROOT+'/'+ROOT+'.zip')=={'inside/':b'', 'inside/Grüße.txt':'Grüße\n'.encode(), 'empty/':b''}
        undo(ROOT+'/'+ROOT+'.zip');passed('Multiple selected folders produce complete entries and undo without changing originals')

        data=io.BytesIO()
        with zipfile.ZipFile(data,'w') as z:z.writestr('existing.txt',b'Keep existing archive\n')
        original=data.getvalue();push('Documents.zip',original)
        nav('/Documents');tap('Up-1');tap('File-1-Documents');tap('ZipButton');wait_status('ZIP created')
        entries=archive('Documents (2).zip')
        assert entries=={'Documents/':b'',**{'Documents/'+p:v for p,v in expected.items()},'Documents/Documents.zip':original}
        assert pull('Documents.zip')==original
        assert 'Documents/Documents (2).zip' not in entries
        d.save_screenshot(str(OUT/'documents-contents-success.png'))
        undo('Documents (2).zip')
        assert pull('Documents.zip')==original and pull(ROOT+'/inside/Grüße.txt')=='Grüße\n'.encode()
        passed('Documents with content and existing ZIP: unique filename, complete original bytes, no self inclusion; Undo preserves originals')

        nav('/Documents');tap('File-1-Documents.zip');tap('ZipButton');wait_status('ZIP created')
        assert archive('Documents (2).zip')=={'Documents.zip':original}
        undo('Documents (2).zip');passed('Existing ZIP treated as a file, archived byte-for-byte and undoable')

        push(ROOT+'/Vanish/file.txt',b'temporary source\n')
        nav('/Documents/'+ROOT);tap('File-1-Vanish')
        d.execute_script('mobile: deleteFolder',{'remotePath':f'@{BUNDLE}:documents/{ROOT}/Vanish'})
        tap('ZipButton');wait_status('ZIP failed')
        nav('/Documents');tap('File-1-'+ROOT);tap('ZipButton');wait_status('ZIP created')
        assert archive(ROOT+'.zip')==expected;undo(ROOT+'.zip')
        passed('Missing source produces an error; UI recovers and the next folder ZIP succeeds')

        d.execute_script('mobile: deleteFile',{'remotePath':f'@{BUNDLE}:documents/Documents.zip'})
        d.execute_script('mobile: deleteFolder',{'remotePath':f'@{BUNDLE}:documents/{ROOT}'})
        select_language(d,'Deutsch');d.terminate_app(BUNDLE);d.activate_app(BUNDLE);time.sleep(.5)
        d.save_screenshot(str(OUT/'final-clean.png'))
        passed('Only test-created files removed; German portrait UI restored')
    except Exception:
        d.save_screenshot(str(OUT/'failure.png'));(OUT/'failure.xml').write_text(d.page_source);raise
    finally: d.quit()

if __name__=='__main__':main()
