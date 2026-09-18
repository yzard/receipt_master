"""Generate private build input, using the actual backend config and Compose port."""
import argparse
import json
import os
import secrets
import sys
from pathlib import Path
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--host', required=True)
args = parser.parse_args()
config = json.load(sys.stdin)
port = config['services']['backend_api']['ports'][0]
endpoint = os.environ.get('RECEIPT_BACKEND_ENDPOINT') or f'http://{args.host}:{port["published"]}/'
url = urlparse(endpoint)
if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.hostname in ('localhost', '0.0.0.0', '127.0.0.1'):
    raise ValueError('Set RECEIPT_BACKEND_ENDPOINT to a phone-accessible HTTP(S) backend URL')
secret_path = args.root / 'playground/secrets/ocr-api-key'
secret_path.parent.mkdir(parents=True, exist_ok=True)
secret_path.parent.chmod(0o700)
try:
    fd = os.open(secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    pass
else:
    with os.fdopen(fd, 'w') as f:
        f.write(secrets.token_urlsafe(32) + '\n')
key = secret_path.read_text().strip()
if len(key) < 24:
    raise ValueError('Backend API key is invalid')
output = args.root / 'build/mobile-config/backend_defaults.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.parent.chmod(0o700)
output.write_text(json.dumps({'endpoint': endpoint, 'api_key': key}) + '\n')
output.chmod(0o600)
print(f'APK backend: {endpoint} (key not displayed)', file=sys.stderr)
