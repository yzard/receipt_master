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
            for name in [
                'src/shared/pubspec.yaml',
                'src/shared/pubspec.lock',
                'docker/android.Dockerfile',
                'docker/android.Dockerfile.dockerignore',
                'docker/apply_mobile_defaults.py',
                'docker/validate_mobile_defaults.py',
                'docker/android_release.py',
                'build_android.sh',
                'bootstrap.json',
                'key',
            ]:
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
                release.atomic_json(
                    staging / 'android-update.json',
                    {
                        'build_number': number,
                        'variants': {'arm64-v8a': {'file': apk.name, 'sha256': release.digest(apk)}},
                    },
                )

            def publish():
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    release.publish(root)
                return out.getvalue().strip()

            manifest(10000)
            self.assertEqual(publish(), 'published')
            old_hash = release.digest(apk)
            self.assertEqual(choose(), 10000)
            self.assertEqual(publish(), 'published')
            apk.write_bytes(b'changed bytes with identical inputs')
            manifest(10000)
            self.assertEqual(publish(), '10001')
            self.assertEqual(
                json.loads((root / 'playground/android-release-state.json').read_text())['build_number'], 10000
            )
            self.assertTrue((root / 'build/mobile/updates' / (old_hash + '.apk')).is_file())
            manifest(10001)
            self.assertEqual(publish(), 'published')
            self.assertFalse((root / 'build/mobile/updates' / (old_hash + '.apk')).exists())
            self.assertEqual(
                {p.name for p in (root / 'build/mobile/updates').glob('*.apk')}, {release.digest(apk) + '.apk'}
            )
            (root / 'bootstrap.json').write_text('new endpoint')
            self.assertEqual(choose(), 10002)

    def test_corrupted_staged_apk_never_publishes_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release.atomic_json(root / 'build/android-candidate.json', {'build_number': 10000, 'input_hash': 'test'})
            staging = root / 'build/android-staging'
            staging.mkdir()
            (staging / 'bad.apk').write_bytes(b'bad')
            release.atomic_json(
                staging / 'android-update.json', {'variants': {'arm64-v8a': {'file': 'bad.apk', 'sha256': '0' * 64}}}
            )
            with self.assertRaises(ValueError):
                release.publish(root)
            self.assertFalse((root / 'build/mobile/android-update.json').exists())
            self.assertFalse((root / 'playground/android-release-state.json').exists())

    def test_latest_release_replaces_both_abis_and_cleans_development_apks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staging = root / 'build/android-staging'
            staging.mkdir(parents=True)
            filenames = {'arm64-v8a': 'receipt-master-arm64.apk', 'x86_64': 'receipt-master-x86_64.apk'}

            def publish(number, abis):
                variants = {}
                for abi in abis:
                    filename = filenames[abi]
                    apk = staging / filename
                    apk.write_bytes(f'{abi} release {number}'.encode())
                    variants[abi] = {'file': filename, 'sha256': release.digest(apk)}
                (staging / 'receipt-master-debug.apk').write_bytes(f'debug release {number}'.encode())
                release.atomic_json(
                    root / 'build/android-candidate.json', {'build_number': number, 'input_hash': str(number)}
                )
                release.atomic_json(staging / 'android-update.json', {'build_number': number, 'variants': variants})
                with contextlib.redirect_stdout(io.StringIO()):
                    release.publish(root)
                return {v['sha256'] + '.apk' for v in variants.values()}

            old_names = publish(10000, list(filenames))
            (staging / 'previous-build.apk').write_bytes(b'old unreferenced staging output')
            (root / 'build/mobile/previous-build.apk').write_bytes(b'old development output')
            current_names = publish(10001, list(filenames))
            updates = root / 'build/mobile/updates'
            self.assertEqual({p.name for p in updates.glob('*.apk')}, current_names)
            self.assertFalse(any((updates / name).exists() for name in old_names))
            self.assertFalse((staging / 'previous-build.apk').exists())
            self.assertFalse((root / 'build/mobile/previous-build.apk').exists())
            self.assertEqual((root / 'build/mobile/receipt_master.apk').read_bytes(), b'arm64-v8a release 10001')
            self.assertEqual((root / 'build/mobile/receipt-master-debug.apk').read_bytes(), b'debug release 10001')
            # Removing an ABI also removes its last named and hash-addressed APKs.
            current_names = publish(10002, ['arm64-v8a'])
            self.assertEqual({p.name for p in updates.glob('*.apk')}, current_names)
            self.assertFalse((staging / filenames['x86_64']).exists())
            self.assertFalse((root / 'build/mobile' / filenames['x86_64']).exists())

    def test_failed_release_keeps_the_last_valid_apks_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staging = root / 'build/android-staging'
            staging.mkdir(parents=True)
            apk = staging / 'receipt-master-arm64.apk'
            apk.write_bytes(b'current valid APK')
            manifest = {
                'build_number': 10000,
                'variants': {'arm64-v8a': {'file': apk.name, 'sha256': release.digest(apk)}},
            }
            release.atomic_json(root / 'build/android-candidate.json', {'build_number': 10000, 'input_hash': 'first'})
            release.atomic_json(staging / 'android-update.json', manifest)
            with contextlib.redirect_stdout(io.StringIO()):
                release.publish(root)
            published = root / 'build/mobile'
            before = {str(p.relative_to(published)): p.read_bytes() for p in published.rglob('*') if p.is_file()}
            apk.write_bytes(b'corrupted candidate APK')
            release.atomic_json(root / 'build/android-candidate.json', {'build_number': 10001, 'input_hash': 'second'})
            with self.assertRaises(ValueError):
                release.publish(root)
            after = {str(p.relative_to(published)): p.read_bytes() for p in published.rglob('*') if p.is_file()}
            self.assertEqual(after, before)


if __name__ == '__main__':
    unittest.main()
