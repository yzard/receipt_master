"""Test the iOS entrypoint lifecycle without claiming native Xcode compilation."""

import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).parents[2]


class IosBuildTest(unittest.TestCase):
    def run_build(self, root, simulator, fail):
        (root / 'docker').mkdir(exist_ok=True)
        (root / 'bin').mkdir(exist_ok=True)
        for name in ['src/shared', 'tests/shared', 'build/mobile-config']:
            (root / name).mkdir(parents=True, exist_ok=True)
        for name in ['build_lifecycle.sh', 'build_cleanup.py', 'build_state.py', 'validate_mobile_defaults.py']:
            shutil.copyfile(ROOT / 'docker' / name, root / 'docker' / name)
        shutil.copyfile(ROOT / 'build_ios.sh', root / 'build_ios.sh')
        (root / 'build/mobile-config/backend_defaults.json').write_text('{"endpoint":"https://receipts.example.com/"}')
        (root / 'docker/prepare_ios_defaults.py').write_text('')
        prepare = root / 'build_android.sh'
        prepare.write_text('#!/bin/sh\nmkdir -p "$(dirname "$0")/build/flutter"\n')
        prepare.chmod(0o755)
        uname = root / 'bin/uname'
        uname.write_text('#!/bin/sh\necho Darwin\n')
        uname.chmod(0o755)
        xcode = root / 'bin/xcodebuild'
        xcode.write_text('#!/bin/sh\necho Xcode-test\n')
        xcode.chmod(0o755)
        flutter = root / 'bin/flutter'
        flutter.write_text('#!' + shutil.which('python3') + '''
import os,sys
from pathlib import Path
assert os.environ['PUB_CACHE'].startswith(os.environ['RECEIPT_BUILD_WORK'])
assert os.environ['CP_CACHE_DIR'].startswith(os.environ['RECEIPT_BUILD_WORK'])
for name in ['PUB_CACHE','CP_CACHE_DIR']:
    target=Path(os.environ[name]);target.mkdir(parents=True,exist_ok=True);(target/'temporary').write_text('cache')
if sys.argv[1:3]==['build','ios']:
    if os.environ['FAIL_IOS']=='1':sys.exit(42)
    simulator='--simulator' in sys.argv
    assert '--debug' in sys.argv if simulator else '--release' in sys.argv
    target=Path('build/ios')/('iphonesimulator' if simulator else 'iphoneos')/'Runner.app'
    target.mkdir(parents=True);(target/'Runner').write_text('application')
''')
        flutter.chmod(0o755)
        dart = root / 'bin/dart'
        dart.write_text('#!/bin/sh\nexit 0\n')
        dart.chmod(0o755)
        env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'], FAIL_IOS=str(int(fail)))
        for name in ['RECEIPT_BUILD_WORK', 'RECEIPT_BUILD_BUILDER', 'RECEIPT_BOOTSTRAP_FILE']:
            env.pop(name, None)
        args = ['bash', str(root / 'build_ios.sh'), str(flutter)] + (['--simulator'] if simulator else [])
        return subprocess.run(args, cwd=root, env=env, capture_output=True, text=True)

    def test_device_and_simulator_export_before_success_cleanup(self):
        for simulator in [False, True]:
            with self.subTest(simulator=simulator), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                result = self.run_build(root, simulator, False)
                self.assertEqual(result.returncode, 0, result.stderr)
                name = 'simulator' if simulator else 'unsigned'
                with zipfile.ZipFile(root / f'build/mobile/receipt-master-ios-{name}.zip') as archive:
                    self.assertEqual(archive.read('Runner.app/Runner'), b'application')
                self.assertFalse((root / 'build/flutter').exists())
                self.assertFalse(list((root / 'build').glob('work.*')))
                self.assertTrue((root / 'build/mobile-config/backend_defaults.json').exists())
                again = self.run_build(root, simulator, False)
                self.assertEqual(again.returncode, 0, again.stderr)
                self.assertIn('reusing the application archive', again.stdout)

    def test_failed_native_build_retains_work_without_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.run_build(root, False, True)
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertTrue((root / 'build/flutter').is_dir())
            self.assertTrue(list((root / 'build').glob('work.*')))
            self.assertFalse((root / 'build/mobile/receipt-master-ios-unsigned.zip').exists())
