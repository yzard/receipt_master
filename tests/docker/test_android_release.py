import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[2] / 'docker/android_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTest(unittest.TestCase):
    def test_unchanged_inputs_and_bytes_reuse_version_and_changed_bytes_bump(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ['src/shared/pubspec.yaml', 'src/shared/pubspec.lock', 'docker/android.Dockerfile', 'docker/android.Dockerfile.dockerignore', 'docker/apply_mobile_defaults.py', 'docker/validate_mobile_defaults.py', 'docker/android_release.py', 'build_android.sh', 'bootstrap.json', 'key']:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(name)
            def choose():
                with contextlib.redirect_stdout(io.StringIO()):
                    release.choose(root, root / 'bootstrap.json', root / 'key')
                return json.loads((root / 'build/android-candidate.json').read_text())['build_number']
            self.assertEqual(choose(), 10000)
            staging = root / 'build/android-staging'
            staging.mkdir()
            apk = staging / 'receipt-master-arm64.apk'
            apk.write_bytes(b'first apk')
            def manifest(number):
                release.atomic_json(staging / 'android-update.json', {'build_number': number, 'variants': {'arm64-v8a': {'file': apk.name, 'sha256': release.digest(apk)}}})
            def publish():
                out = io.StringIO()
                with contextlib.redirect_stdout(out): release.publish(root)
                return out.getvalue().strip()
            manifest(10000)
            self.assertEqual(publish(), 'published')
            old_hash = release.digest(apk)
            self.assertEqual(choose(), 10000)
            self.assertEqual(publish(), 'published')
            apk.write_bytes(b'changed bytes with identical inputs')
            manifest(10000)
            self.assertEqual(publish(), '10001')
            self.assertEqual(json.loads((root / 'playground/android-release-state.json').read_text())['build_number'], 10000)
            manifest(10001)
            self.assertEqual(publish(), 'published')
            self.assertTrue((root / 'build/mobile/updates' / (old_hash + '.apk')).is_file())
            (root / 'bootstrap.json').write_text('new endpoint')
            self.assertEqual(choose(), 10002)

    def test_corrupted_staged_apk_never_publishes_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release.atomic_json(root / 'build/android-candidate.json', {'build_number': 10000, 'input_hash': 'test'})
            staging = root / 'build/android-staging'
            staging.mkdir()
            (staging / 'bad.apk').write_bytes(b'bad')
            release.atomic_json(staging / 'android-update.json', {'variants': {'arm64-v8a': {'file': 'bad.apk', 'sha256': '0' * 64}}})
            with self.assertRaises(ValueError): release.publish(root)
            self.assertFalse((root / 'build/mobile/android-update.json').exists())
            self.assertFalse((root / 'playground/android-release-state.json').exists())


if __name__ == '__main__': unittest.main()
