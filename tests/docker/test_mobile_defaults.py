import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'mobile_defaults', Path(__file__).parents[2] / 'docker/validate_mobile_defaults.py'
)
mobile_defaults = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile_defaults)


class MobileDefaultsTest(unittest.TestCase):
    def test_release_requires_backend_address_without_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'defaults.json'
            for config in [
                {},
                {'endpoint': 'http://127.0.0.1:5000/', 'api_key': 'x' * 32},
                {'endpoint': 'http://192.168.1.20:5000/', 'api_key': ''},
            ]:
                path.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    mobile_defaults.validate(path)
            for endpoint in ['http://192.168.1.20:5000/', 'https://receipts.example.com/']:
                path.write_text(json.dumps({'endpoint': endpoint}))
                mobile_defaults.validate(path)


if __name__ == '__main__':
    unittest.main()
