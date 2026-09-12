"""Run all device suites sequentially, preserving logs and stopping on failure."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(os.environ.get('QA_RUN_ROOT', 'parity-evidence/iphone-usability-qa/final'))
root.mkdir(parents=True, exist_ok=True)
suites = [('guards', 'usability_regression_test.py'), ('edges', 'usability_regression_test.py'),
          ('acceptance', 'app_store_qa_test.py'), ('drag', 'iphone_drag_qa_test.py'),
          ('toolbar', 'usability_regression_test.py')]
start = os.environ.get('QA_START_CASE', 'guards')
results = []
for name, script in suites[suites.index(next(s for s in suites if s[0] == start)):]:
    out = root / name
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, IOS_UDID='00008030-000E54823A91402E', IOS_DEVICE_NAME='iPhone 11',
               IOS_VERSION='26.6.1', QA_SUITE=name, QA_FIXTURE='OpenCommanderUsabilityQA',
               QA_EVIDENCE=str(out), APPIUM_SERVER='http://127.0.0.1:4753', WDA_URL='http://127.0.0.1:8153')
    print('START', name, flush=True)
    began = time.monotonic()
    with (out / 'run.log').open('w') as log:
        process = subprocess.Popen([sys.executable, '-u', 'ios/' + script], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            log.write(line); log.flush()
            if line.startswith(('PASS', 'FAIL', 'RESULT', 'Traceback', 'AssertionError')):
                print(name + ': ' + line.rstrip(), flush=True)
        code = process.wait()
    results.append({'suite': name, 'exit_code': code, 'seconds': round(time.monotonic() - began, 1)})
    (root / ('runner-' + start + '.json')).write_text(json.dumps(results, indent=2) + '\n')
    print('END', name, 'exit', code, flush=True)
    if code: raise SystemExit(code)
    if os.environ.get('QA_STOP_CASE') == name: break
