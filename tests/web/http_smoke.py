"""Exercise the built API/Web image with disposable users and data, without a GPU."""

import argparse
import hashlib
import http.cookiejar
import io
import json
import os
import re
import secrets
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zipfile
import zlib
from pathlib import Path


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


class Browser:
    def __init__(self, origin):
        self.origin = origin
        self.client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, path, body=None, method=None, raw=None, content_type=None):
        payload = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.origin + path, data=payload, method=method)
        if payload is not None:
            request.add_header('Content-Type', content_type or 'application/json')
            request.add_header('Origin', self.origin)
        try:
            response = self.client.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        data = response.read()
        return (
            response.status,
            response.headers,
            json.loads(data) if response.headers.get_content_type() == 'application/json' else data,
        )

    def op(self, component, action, data=None):
        status, _, body = self.request(
            f'/api/v1/{component}/{action}', {'request_key': str(uuid.uuid4()), 'input': data or {}}
        )
        assert status == 200, (component, action, status, body)
        return body['data']

    def sign_in(self, name, password, new_password):
        status, headers, body = self.request('/api/auth/login', {'username': name, 'password': password})
        assert status == 200
        assert body['user']['must_change_password']
        assert 'refresh_token' not in body
        assert all('HttpOnly' in v and 'SameSite=Strict' in v for v in headers.get_all('Set-Cookie'))
        assert self.request('/api/v1/receipts/list', {'input': {}})[0] == 403
        assert self.request('/receipt_master.apk')[0] == 403
        status, _, body = self.request(
            '/api/auth/change-password', {'current_password': password, 'new_password': new_password}
        )
        assert status == 200 and not body['user']['must_change_password']
        return body['access_token']


def png():
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))

    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', 10, 20, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress((b'\0' + b'\xff' * 30) * 20))
        + chunk(b'IEND', b'')
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', default='receipt-master-backend-api:latest')
    parser.add_argument('--artifacts', required=True, type=Path)
    args = parser.parse_args()
    name = 'receipt-web-smoke-' + uuid.uuid4().hex[:12]
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='receipt-web-auth-') as temporary:
        data = Path(temporary)
        config = (
            (root / 'docker/defaults/backend_api.toml')
            .read_text()
            .replace('jwt_secret = ""', f'jwt_secret = "{secrets.token_urlsafe(32)}"')
            .replace('api_key = ""', f'api_key = "{secrets.token_urlsafe(32)}"')
            .replace('http://backend_ocr:8000', 'http://127.0.0.1:9')
        )
        (data / 'config.toml').write_text(config)
        (data / 'config.toml').chmod(0o600)
        (data / 'prompt.toml').write_text((root / 'docker/defaults/prompt.toml').read_text())

        def start(reset=False):
            docker(
                'run',
                '--detach',
                '--rm',
                '--name',
                name,
                '--publish',
                '127.0.0.1::8000',
                '--env',
                f'PUID={os.getuid()}',
                '--env',
                f'PGID={os.getgid()}',
                '--env',
                f'RESET_ADMIN_PASSWORD={str(reset).lower()}',
                '--volume',
                f'{data}:/data',
                args.image,
            )
            # Downloads must come from the image; only persistent business data is mounted.
            mounts = json.loads(docker('inspect', name))[0]['Mounts']
            assert {mount['Destination'] for mount in mounts} == {'/data'}, mounts
            port = docker('port', name, '8000/tcp').rsplit(':', 1)[1]
            origin = f'http://127.0.0.1:{port}'
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                try:
                    if Browser(origin).request('/health')[0] == 200:
                        return origin
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.2)
            raise AssertionError('Disposable API container did not become ready')

        try:
            origin = start()
            process = docker('exec', name, 'cat', '/proc/1/status')
            for field, identity in [('Uid', os.getuid()), ('Gid', os.getgid())]:
                values = re.search(rf'^{field}:\s+(.+)$', process, re.MULTILINE).group(1).split()
                assert [int(value) for value in values] == [identity] * 4, (field, values)
            admin = Browser(origin)
            status, headers, page = admin.request('/')
            assert status == 200 and b'<div id="root">' in page
            assert "frame-ancestors 'none'" in headers['Content-Security-Policy']
            assert headers['X-Content-Type-Options'] == 'nosniff'
            for asset in re.findall(rb'(?:src|href)="(/assets/[^\"]+)"', page):
                assert admin.request(asset.decode())[0] == 200
            for path in ['/receipt_master.apk', '/android-update.json', '/updates/' + 'a' * 64 + '.apk']:
                assert admin.request(path)[0] == 401
            token = admin.sign_in('admin', 'admin', 'synthetic-admin-password-123')
            status, _, created = admin.request(
                '/api/auth/users', {'username': 'tester', 'password': 'synthetic-temp-password-123'}
            )
            assert status == 200 and not created['is_admin']
            user = Browser(origin)
            user.sign_in('tester', 'synthetic-temp-password-123', 'synthetic-user-password-123')
            assert user.request('/api/auth/users', method='GET')[0] == 403
            assert (
                user.request('/api/auth/users', {'username': 'other', 'password': 'synthetic-other-password-123'})[0]
                == 403
            )
            assert admin.request('/api/auth/users/admin', method='DELETE')[0] == 403
            receipt = {
                'id': str(uuid.uuid4()),
                'store': 'Synthetic private store',
                'recognizedStore': '',
                'branch': '',
                'address': '',
                'country': 'US',
                'currency': 'USD',
                'timeSource': 'user_entered',
                'rawTime': '',
                'totalSource': 'user_entered',
                'occurredAt': 1780000000000,
                'createdAt': 1,
                'revision': 0,
                'totalMinor': 0,
                'posted': False,
                'lines': [],
            }
            saved = user.op('receipts', 'create', {'receipt': receipt})
            assert admin.op('receipts', 'list')['items'] == []
            assert admin.request('/api/v1/receipts/get', {'input': {'id': saved['id']}})[0] == 404
            image_ids = []
            for position in range(2):
                boundary = 'receipt-' + uuid.uuid4().hex
                metadata = json.dumps(
                    {
                        'request_key': str(uuid.uuid4()),
                        'input': {
                            'receipt_id': saved['id'],
                            'expected_version': saved['revision'],
                            'captured_at_utc_ms': None,
                        },
                    }
                ).encode()
                body = (
                    b'--'
                    + boundary.encode()
                    + b'\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n'
                    + metadata
                    + b'\r\n--'
                    + boundary.encode()
                    + b'\r\nContent-Disposition: form-data; name="photo"; filename="receipt.png"\r\nContent-Type: image/png\r\n\r\n'
                    + png()
                    + b'\r\n--'
                    + boundary.encode()
                    + b'--\r\n'
                )
                status, _, uploaded = user.request(
                    '/api/v1/images/upload', raw=body, content_type=f'multipart/form-data; boundary={boundary}'
                )
                assert status == 200, uploaded
                saved = uploaded['data']['receipt']
                image_ids.append(uploaded['data']['image_id'])
            images = user.op('images', 'list', {'receipt_id': saved['id']})
            assert len(images) == 2
            for image in images:
                assert user.request('/api/v1/media/' + image['media_id'])[0] == 200
                assert admin.request('/api/v1/media/' + image['media_id'])[0] == 404
            user.op(
                'images',
                'rotate',
                {'receipt_id': saved['id'], 'expected_version': saved['revision'], 'id': image_ids[0]},
            )
            saved = user.op('receipts', 'get', {'id': saved['id']})
            job = user.op(
                'recognition',
                'start',
                {'receipt_id': saved['id'], 'expected_version': saved['revision'], 'zone': 'UTC'},
            )
            assert admin.request('/api/v1/recognition/get', {'input': {'id': job['job_id']}})[0] == 404
            assert len(user.op('receipts', 'list')['items']) == 1
            for component in ['printed_names', 'product_names', 'categories', 'logos']:
                assert isinstance(user.op(component, 'list'), list)
            trend = user.op(
                'reports', 'trend', {'period': 'month', 'window': 0, 'anchor': 1780000000000, 'zone': 'UTC'}
            )
            assert trend['currency'] == 'USD' and trend['points']
            assert user.request('/api/auth/refresh', {})[0] == 200
            assert user.request('/api/auth/me', method='GET')[0] == 200
            # Verify the delivered APK is exactly the signed build artifact.
            status, _, apk = admin.request('/receipt_master.apk')
            assert status == 200, ('Image-embedded APK download failed', status)
            assert (
                hashlib.sha256(apk).digest()
                == hashlib.sha256((args.artifacts / 'receipt_master.apk').read_bytes()).digest()
            )
            with zipfile.ZipFile(io.BytesIO(apk)) as archive:
                defaults = json.loads(archive.read('assets/flutter_assets/resources/backend_defaults.json'))
                assert set(defaults) == {'endpoint'}, 'APK must contain an endpoint only, without shared credentials'
                assert defaults == json.loads((root / 'build/mobile-config/backend_defaults.json').read_text())
            assert user.request('/receipt_master.apk')[0] == 200
            status, _, manifest = user.request('/android-update.json')
            assert status == 200
            assert manifest == json.loads((args.artifacts / 'android-update.json').read_text())
            current_names = {Path(variant['path']).name for variant in manifest['variants'].values()}
            installed_names = set(
                docker(
                    'exec', name, 'find', '/artifacts/updates', '-type', 'f', '-name', '*.apk', '-printf', '%f\n'
                ).splitlines()
            )
            assert installed_names == current_names, 'API image must contain only the current update APKs'
            assert {p.name for p in (args.artifacts / 'updates').glob('*.apk')} == current_names
            assert user.request('/updates/' + 'a' * 64 + '.apk')[0] == 404
            for variant in manifest['variants'].values():
                status, _, update = user.request(variant['path'])
                assert status == 200
                assert len(update) == variant['bytes']
                assert hashlib.sha256(update).hexdigest() == variant['sha256']
            assert hashlib.sha256(apk).hexdigest() == manifest['variants']['arm64-v8a']['sha256']
            assert (data / 'database/auth.sqlite').stat().st_uid == os.getuid()
            assert (data / 'database/auth.sqlite').stat().st_gid == os.getgid()
            assert (data / 'database/auth.sqlite').stat().st_mode & 0o077 == 0
            assert (data / 'database/receipts.sqlite').is_file()
            assert not (data / 'auth.sqlite').exists()
            docker('stop', '--time', '10', name)
            origin = start(reset=True)
            user.origin = origin
            admin = Browser(origin)
            stale = urllib.request.Request(origin + '/api/auth/me', headers={'Authorization': f'Bearer {token}'})
            try:
                urllib.request.urlopen(stale, timeout=10)
                raise AssertionError('Reset failed to revoke the admin JWT')
            except urllib.error.HTTPError as error:
                assert error.code == 401
            admin.sign_in('admin', 'admin', 'synthetic-admin-password-456')
            assert admin.request('/api/auth/users/' + created['user_id'], method='DELETE')[0] == 200
            assert user.request('/receipt_master.apk')[0] == 401
            deadline = time.monotonic() + 10
            while (data / 'users' / created['user_id']).exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert not (data / 'users' / created['user_id']).exists()
            assert (data / 'database/auth.sqlite').exists()
            print(
                'HTTP smoke passed: static Web, cookies, forced change, roles, isolated receipts/photos/jobs, multi-photo upload, rotation, reports, image-embedded APK/update hashes without artifact mounts, UID/mode, runtime RESET and user cleanup.'
            )
        finally:
            subprocess.run(
                ['docker', 'stop', '--time', '10', name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )


if __name__ == '__main__':
    main()
