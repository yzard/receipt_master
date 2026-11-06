"""Configuration preparation never invents shared credentials or changes live data."""
import importlib.util
import tempfile
import unittest
import shutil
import tomllib
from pathlib import Path
spec = importlib.util.spec_from_file_location('prepare', Path(__file__).parents[1] / 'docker/prepare_playground_config.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

class PrepareConfigTest(unittest.TestCase):
    def test_fresh_config_and_repeat_preserve_operator_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(Path(__file__).parents[1] / 'docker/defaults', root / 'docker/defaults')
            path = prepare.prepare(root)
            config = tomllib.loads(path.read_text())
            self.assertGreaterEqual(len(config['general']['jwt_secret']), 24)
            self.assertEqual(config['inference']['api_key'], '')
            self.assertFalse((root / 'playground/backend_ocr').exists())
            edited = path.read_text().replace('api_key = ""', 'api_key = "shared-key"')
            path.write_text(edited)
            prepare.prepare(root)
            self.assertEqual(path.read_text(), edited)

    def test_old_endpoint_is_never_silently_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'playground/backend_api/config.toml'
            path.parent.mkdir(parents=True)
            original = '[general]\njwt_secret="preserved"\n[ocr]\nurl="http://backend_ocr:8000"\napi_key="old-key"\n'
            path.write_text(original)
            with self.assertRaisesRegex(ValueError, 'Migrate'):
                prepare.prepare(root)
            self.assertEqual(path.read_text(), original)
