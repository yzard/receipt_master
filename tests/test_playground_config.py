"""Runtime TOML owns both persistent keys without separate secret files."""

import shutil
import tempfile
import tomllib
import unittest
from pathlib import Path

from docker.prepare_playground_config import prepare


class PlaygroundConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(Path(__file__).parents[1] / 'docker/defaults', self.root / 'docker/defaults')

    def settings(self):
        data = self.root / 'playground/data'
        return (tomllib.loads((data / 'backend_api.toml').read_text()),
                tomllib.loads((data / 'backend_ocr.toml').read_text()))

    def test_install_embeds_existing_client_key_and_preserves_edits(self):
        legacy = self.root / 'playground/secrets/ocr-api-key'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('existing-persistent-key-with-enough-length\n')
        api_path = prepare(self.root)
        api, ocr = self.settings()
        self.assertEqual(api['general']['api_key'], 'existing-persistent-key-with-enough-length')
        self.assertNotEqual(api['ocr']['api_key'], api['general']['api_key'])
        self.assertEqual(api['ocr']['api_key'], ocr['general']['api_key'])
        self.assertEqual(set(api['ocr']), {'url', 'api_key'})
        self.assertFalse(legacy.exists())
        self.assertEqual(api_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((api_path.parent / 'backend_ocr.toml').stat().st_mode & 0o777, 0o600)
        self.assertFalse((api_path.parent / 'api-key').exists())
        self.assertFalse((api_path.parent / 'ocr-api-key').exists())
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

    def test_moves_nested_config_to_data_root(self):
        api_path = prepare(self.root)
        data = api_path.parent
        nested = data / 'config'
        nested.mkdir()
        for name in ('backend_api.toml', 'backend_ocr.toml', 'prompt.toml'):
            (data / name).replace(nested / name)
        prompt = nested / 'prompt.toml'
        prompt.write_text(prompt.read_text() + '\n# retained edit\n')
        self.assertEqual(prepare(self.root), api_path)
        self.assertFalse(nested.exists())
        self.assertIn('# retained edit', (data / 'prompt.toml').read_text())

    def test_upgrades_old_ocr_settings_and_key_files(self):
        api_path = prepare(self.root)
        data = api_path.parent
        api, ocr = self.settings()
        client_key, service_key = api['general']['api_key'], api['ocr']['api_key']
        (data / 'api-key').write_text(client_key + '\n')
        (data / 'ocr-api-key').write_text(service_key + '\n')
        api['general'].pop('api_key')
        api['general']['api_key_file'] = '/data/api-key'
        api['general']['served_model'] = 'receipt-qwen3.8'
        api['general'].pop('repair_attempts')
        api['ocr'] = {'url': api['ocr']['url'], 'model': 'old-model', 'output_tokens': 7000,
                      'max_images': 8, 'thinking': False, 'prompt_file': '/data/prompt.toml',
                      'repair_attempts': 2, 'api_key_file': '/data/ocr-api-key'}
        api['pricing'] = {'input_usd_per_million_tokens': '1'}
        api['budget'] = {'alert_percent': 80, 'timezone': 'UTC'}
        ocr['general'].pop('api_key')
        ocr['general']['api_key_file'] = '/data/ocr-api-key'
        for name in ('receipt_output_tokens', 'logo_output_tokens', 'thinking', 'temperature', 'seed'):
            ocr['engine'].pop(name)
        from docker.prepare_playground_config import write_sections
        write_sections(api_path, api)
        write_sections(data / 'backend_ocr.toml', ocr)
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
        self.assertFalse((data / 'api-key').exists())
        self.assertFalse((data / 'ocr-api-key').exists())


if __name__ == '__main__':
    unittest.main()
