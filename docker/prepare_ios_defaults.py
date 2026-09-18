"""Inject a private backend endpoint into the assembled iOS workspace only."""
import json
import plistlib
import shutil
import sys
from pathlib import Path
from urllib.parse import urlparse

workspace, source = map(Path, sys.argv[1:])
config = json.loads(source.read_text())
url = urlparse(config['endpoint'])
if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password:
    raise SystemExit('Invalid backend endpoint')
resources = workspace / 'resources'
if resources.is_symlink():
    original = resources.resolve()
    resources.unlink()
    shutil.copytree(original, resources)
shutil.copyfile(source, resources / 'backend_defaults.json')
plist_path = workspace / 'ios/Runner/Info.plist'
with plist_path.open('rb') as file:
    info = plistlib.load(file)
if url.scheme == 'http':
    info['NSAppTransportSecurity'] = {
        'NSExceptionDomains': {
            url.hostname: {'NSExceptionAllowsInsecureHTTPLoads': True, 'NSIncludesSubdomains': False}
        }
    }
with plist_path.open('wb') as file:
    plistlib.dump(info, file)
