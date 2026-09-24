"""Service-specific data roots and persistent credentials."""

import shutil
import tempfile
import tomllib
import unittest
from pathlib import Path

from docker.prepare_playground_config import prepare, write_sections


class PlaygroundConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(Path(__file__).parents[1] / 'docker/defaults', self.root / 'docker/defaults')

    def paths(self):
        return (self.root / 'playground/backend_api/config.toml',
                self.root / 'playground/backend_ocr/config.toml')

    def settings(self):
        return tuple(tomllib.loads(path.read_text()) for path in self.paths())

    def test_install_embeds_keys_and_preserves_edits(self):
        legacy_key = self.root / 'playground/secrets/ocr-api-key'
        legacy_key.parent.mkdir(parents=True)
        legacy_key.write_text('existing-persistent-key-with-enough-length\n')
        api_path = prepare(self.root)
        api, ocr = self.settings()
        self.assertEqual(api_path, self.paths()[0])
        self.assertEqual(api['general']['api_key'], 'existing-persistent-key-with-enough-length')
        self.assertNotEqual(api['ocr']['api_key'], api['general']['api_key'])
        self.assertEqual(api['ocr']['api_key'], ocr['general']['api_key'])
        self.assertEqual(set(api['ocr']), {'url', 'api_key'})
        self.assertNotIn('logos', api)
        self.assertNotIn('data_dir', api['general'])
        self.assertFalse(legacy_key.exists())
        for path in self.paths():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        prompt = api_path.parent / 'prompt.toml'
        prompt.write_text(prompt.read_text() + '\n# operator edit\n')
        before = api_path.read_bytes()
        prepare(self.root)
        self.assertEqual(api_path.read_bytes(), before)
        self.assertIn('# operator edit', prompt.read_text())

    def test_conflicting_existing_keys_fail_without_overwrite(self):
        api_path = prepare(self.root)
        before = api_path.read_bytes()
        old = api_path.parent / 'api-key'
        old.write_text('another-valid-but-different-api-key\n')
        with self.assertRaisesRegex(ValueError, 'differ'):
            prepare(self.root)
        self.assertEqual(api_path.read_bytes(), before)
        self.assertTrue(old.exists())

    def test_moves_existing_database_media_and_config_into_service_roots(self):
        legacy = self.root / 'playground/data'
        (legacy / 'database').mkdir(parents=True)
        (legacy / 'database/receipts.sqlite').write_bytes(b'preserved-db')
        (legacy / 'media').mkdir()
        (legacy / 'media/image.jpg').write_bytes(b'preserved-photo')
        for name in ('backend_api.toml', 'backend_ocr.toml', 'prompt.toml'):
            (legacy / name).write_bytes((self.root / 'docker/defaults' / name).read_bytes())
        prepare(self.root)
        api_path, ocr_path = self.paths()
        self.assertFalse(legacy.exists())
        self.assertEqual((api_path.parent / 'database/receipts.sqlite').read_bytes(), b'preserved-db')
        self.assertEqual((api_path.parent / 'media/image.jpg').read_bytes(), b'preserved-photo')
        self.assertFalse((ocr_path.parent / 'database').exists())
        self.assertFalse((ocr_path.parent / 'prompt.toml').exists())
        self.assertNotIn('data_dir', self.settings()[0]['general'])

    def test_layout_conflict_does_not_move_existing_files(self):
        prepare(self.root)
        legacy = self.root / 'playground/data'
        legacy.mkdir()
        (legacy / 'backend_api.toml').write_text('conflict')
        with self.assertRaisesRegex(ValueError, 'Conflicting legacy data'):
            prepare(self.root)
        self.assertTrue((legacy / 'backend_api.toml').exists())

    def test_flattens_service_data_subdirectories(self):
        prepare(self.root)
        for path in self.paths():
            nested = path.parent / 'data'
            nested.mkdir()
            path.replace(nested / 'config.toml')
            if path == self.paths()[0]:
                (path.parent / 'prompt.toml').replace(nested / 'prompt.toml')
                (nested / 'database').mkdir()
                (nested / 'database/receipts.sqlite').write_bytes(b'existing')
        prepare(self.root)
        self.assertTrue(all(path.exists() for path in self.paths()))
        self.assertEqual((self.paths()[0].parent / 'database/receipts.sqlite').read_bytes(), b'existing')
        self.assertFalse((self.paths()[0].parent / 'data').exists())
        self.assertFalse((self.paths()[1].parent / 'data').exists())

    def test_upgrades_old_ocr_settings_and_key_files(self):
        api_path = prepare(self.root)
        api, ocr = self.settings()
        client_key, service_key = api['general']['api_key'], api['ocr']['api_key']
        (api_path.parent / 'api-key').write_text(client_key + '\n')
        (api_path.parent / 'ocr-api-key').write_text(service_key + '\n')
        api['general'].pop('api_key')
        api['general']['api_key_file'] = '/data/api-key'
        api['general']['served_model'] = 'receipt-qwen3.8'
        api['general']['data_dir'] = '/data'
        api['general'].pop('repair_attempts')
        api['ocr'] = {'url': api['ocr']['url'], 'model': 'old-model', 'output_tokens': 7000,
                      'max_images': 8, 'thinking': False, 'prompt_file': '/data/prompt.toml',
                      'repair_attempts': 2, 'api_key_file': '/data/ocr-api-key'}
        api['pricing'] = {'input_usd_per_million_tokens': '1'}
        api['budget'] = {'alert_percent': 80, 'timezone': 'UTC'}
        api['logos'] = {'enabled': False}
        ocr['general'].pop('api_key')
        ocr['general']['api_key_file'] = '/data/ocr-api-key'
        for name in ('receipt_output_tokens', 'logo_output_tokens', 'thinking', 'temperature', 'seed'):
            ocr['engine'].pop(name)
        write_sections(api_path, api)
        write_sections(self.paths()[1], ocr)
        prepare(self.root)
        api, ocr = self.settings()
        self.assertEqual(api['general']['api_key'], client_key)
        self.assertEqual(api['ocr']['api_key'], service_key)
        self.assertEqual(ocr['general']['api_key'], service_key)
        self.assertEqual(api['general']['repair_attempts'], 2)
        self.assertEqual(ocr['engine']['receipt_output_tokens'], 7000)
        self.assertEqual(ocr['engine']['max_images'], 8)
        self.assertFalse(ocr['engine']['thinking'])
        self.assertNotIn('pricing', api)
        self.assertNotIn('logos', api)
        self.assertNotIn('data_dir', api['general'])
        self.assertFalse((api_path.parent / 'api-key').exists())
        self.assertFalse((api_path.parent / 'ocr-api-key').exists())


if __name__ == '__main__':
    unittest.main()
