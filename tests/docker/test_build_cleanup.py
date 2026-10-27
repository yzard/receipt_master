import fcntl
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('cleanup', ROOT / 'docker/build_cleanup.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTest(unittest.TestCase):
    def test_success_preserves_deliverables_identity_reports_and_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / 'build/work.test'
            work.mkdir(parents=True)
            keep = [
                'build/mobile/receipt_master.apk',
                'build/mobile/updates/current.apk',
                'build/mobile/android-update.json',
                'build/android-signing/debug.keystore',
                'playground/android-release-state.json',
                'playground/backend_api/config.toml',
                'build/evaluations/report.json',
                'build/web/index.html',
                'build/mobile/receipt-master-ios-unsigned.zip',
            ]
            for name in keep + cleanup.ANDROID + cleanup.NATIVE:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'keep' if name in keep else b'temporary')
            target = root / cleanup.RUST[0]
            target.mkdir(parents=True)
            (target / 'CACHEDIR.TAG').write_text('Signature: 8a477f597d28d172789f06886806bc55')
            cleanup.clean(root, work, 'docker', 1)
            self.assertFalse(work.exists())
            self.assertFalse(target.exists())
            for name in cleanup.ANDROID + cleanup.NATIVE:
                self.assertFalse((root / name).exists(), name)
            for name in keep:
                self.assertEqual((root / name).read_bytes(), b'keep', name)

    def test_symlink_or_active_rust_build_preserves_outputs(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as outside:
            root = Path(tmp)
            work = root / 'build/work.test'
            work.mkdir(parents=True)
            (root / 'build/android-staging').symlink_to(outside, target_is_directory=True)
            marker = Path(outside) / 'other-project'
            marker.write_text('keep')
            with self.assertRaises(ValueError):
                cleanup.clean(root, work, 'docker', 1)
            self.assertTrue(marker.exists())
            (root / 'build/android-staging').unlink()
            target = root / cleanup.RUST[0]
            (target / 'debug').mkdir(parents=True)
            (target / 'CACHEDIR.TAG').write_text('Signature: 8a477f597d28d172789f06886806bc55')
            with (target / 'debug/.cargo-lock').open('w') as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    cleanup.clean(root, work, 'docker', 1)
            self.assertTrue(target.exists())
            self.assertTrue(work.exists())

    def test_ios_export_survives_workspace_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / 'build/work.test'
            work.mkdir(parents=True)
            source = root / 'build/flutter/build/ios/iphoneos/Runner.app'
            source.mkdir(parents=True)
            (source / 'Runner').write_text('application')
            target = root / 'build/mobile/receipt-master-ios-unsigned.zip'
            cleanup.export_ios(source, target)
            cleanup.clean(root, work, 'ios', 1)
            self.assertTrue(target.is_file())
            self.assertFalse(source.exists())

    def test_web_export_replaces_old_chunks_without_touching_other_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'work/web'
            source.mkdir(parents=True)
            (source / 'index.html').write_text('new')
            target = root / 'build/web'
            target.mkdir(parents=True)
            (target / 'index.html').write_text('old')
            (target / 'stale.js').write_text('old')
            cleanup.export_web(source, target)
            self.assertEqual((target / 'index.html').read_text(), 'new')
            self.assertFalse((target / 'stale.js').exists())

    def test_root_owned_legacy_files_use_only_the_validated_project_mount(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            work = root / 'build/work.test'
            work.mkdir(parents=True)
            argv = [
                'build_cleanup.py',
                'clean',
                '--root',
                str(root),
                '--work',
                str(work),
                '--component',
                'docker',
                '--owner',
                '1',
            ]
            with patch.object(cleanup.sys, 'argv', argv), patch.object(cleanup.sys, 'platform', 'linux'), patch.object(
                cleanup.os, 'geteuid', return_value=1000
            ), patch.object(cleanup, 'clean', side_effect=PermissionError), patch.object(
                cleanup.subprocess, 'run'
            ) as run:
                cleanup.main()
            command = run.call_args.args[0]
            self.assertIn(f'type=bind,source={root},target={root}', command)
            self.assertEqual(command[:5], ['docker', 'run', '--rm', '--user', '0:0'])
            self.assertNotIn('prune', command)

    def lifecycle(self, root, result=0, cleanup_failure=False):
        (root / 'docker').mkdir()
        for filename in ['build_lifecycle.sh', 'build_cleanup.py']:
            shutil.copyfile(ROOT / 'docker' / filename, root / 'docker' / filename)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        stub = bin_dir / 'docker'
        stub.write_text('#!' + shutil.which('python3') + '''
import json,os,sys
from pathlib import Path
with Path(os.environ['LOG']).open('a') as handle: handle.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:3]==['buildx','rm'] and os.environ.get('RM_FAIL')=='1': sys.exit(37)
''')
        stub.chmod(0o755)
        script = root / 'parent.sh'
        script.write_text('''set -euo pipefail
project_dir="$PWD"
source "$project_dir/docker/build_lifecycle.sh"
receipt_build_start docker
receipt_builder_start
mkdir -p build/mobile build/android-staging
printf release > build/mobile/receipt_master.apk
printf temporary > build/android-staging/scratch
bash -c 'set -euo pipefail; project_dir="$PWD"; source docker/build_lifecycle.sh; receipt_build_start web; receipt_docker_build --target artifacts .'
exit ''' + str(result))
        env = dict(
            os.environ,
            PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
            LOG=str(root / 'log'),
            RM_FAIL=str(int(cleanup_failure)),
        )
        for name in ['RECEIPT_BUILD_WORK', 'RECEIPT_BUILD_BUILDER']:
            env.pop(name, None)
        return subprocess.run(['bash', str(script)], cwd=root, env=env, text=True, capture_output=True)

    def test_one_builder_for_nested_scripts_and_success_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.lifecycle(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'log').read_text().splitlines()]
            creates = [c for c in calls if c[:2] == ['buildx', 'create']]
            removes = [c for c in calls if c[:2] == ['buildx', 'rm']]
            self.assertEqual(len(creates), 1)
            self.assertEqual(removes, [['buildx', 'rm', creates[0][3]]])
            self.assertFalse(list((root / 'build').glob('work.*')))
            self.assertFalse((root / 'build/android-staging').exists())
            self.assertTrue((root / 'build/mobile/receipt_master.apk').exists())
            self.assertFalse(any('prune' in c for c in calls))

    def test_build_and_cleanup_failures_keep_diagnostics_and_return_failure(self):
        for code, cleanup_failure in [(19, False), (0, True)]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                result = self.lifecycle(root, code, cleanup_failure)
                self.assertEqual(result.returncode, code or 37, result.stderr)
                self.assertTrue(list((root / 'build').glob('work.*')))
                self.assertTrue((root / 'build/android-staging/scratch').exists())
                self.assertTrue((root / 'build/mobile/receipt_master.apk').exists())
                self.assertIn('diagnostics retained', result.stderr)
