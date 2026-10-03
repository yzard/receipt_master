"""iOS bootstrap isolation and transport policy regression checks."""
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / 'docker/prepare_ios_defaults.py'


class IOSDefaultsTest(unittest.TestCase):
    def test_bootstrap_isolated_and_transport_policy_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            canonical = root / 'canonical'
            canonical.mkdir()
            (canonical / 'backend_defaults.json').write_text('{}')
            workspace = root / 'workspace'
            runner = workspace / 'ios/Runner'
            runner.mkdir(parents=True)
            plist = runner / 'Info.plist'
            plist.write_bytes(plistlib.dumps({'CFBundleName': 'receipt_master'}))
            (workspace / 'resources').symlink_to(canonical)
            source = root / 'bootstrap.json'
            for config in [
                {'endpoint': 'http://192.168.1.12:5000'},
                {'endpoint': 'https://example.test'},
                {},
            ]:
                source.write_text(json.dumps(config))
                subprocess.run([sys.executable, str(SCRIPT), str(workspace), str(source)], check=True)
                info = plistlib.loads(plist.read_bytes())
                if config.get('endpoint', '').startswith('http:'):
                    domains = info['NSAppTransportSecurity']['NSExceptionDomains']
                    self.assertEqual(list(domains), ['192.168.1.12'])
                    self.assertTrue(domains['192.168.1.12']['NSExceptionAllowsInsecureHTTPLoads'])
                else:
                    self.assertNotIn('NSAppTransportSecurity', info)
                self.assertEqual(json.loads((workspace / 'resources/backend_defaults.json').read_text()), config)
                self.assertEqual((canonical / 'backend_defaults.json').read_text(), '{}')


if __name__ == '__main__':
    unittest.main()
