"""Exercise durable background recognition against a running playground; delete only probes."""

import argparse
import hashlib
import json
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


def photo_groups(scenario):
    if scenario == 'logo':
        return [[(Path(__file__).parent / 'corpus/images/3a8e3c19-0.jpg').read_bytes()]]
    if scenario == 'parallel':
        return [
            [(Path(__file__).parent / 'corpus/images' / f'{name}-0.jpg').read_bytes()]
            for name in ['b92bd0ff', '2f083787']
        ]
    import io

    from PIL import Image, ImageDraw, ImageFont

    pages = []
    for lines in [
        ['TEST MARKET', '09/16/2026 12:30', '1 MILK          3.00', '1 BREAD         2.00', '1 EGGS          4.00'],
        [
            'TEST MARKET',
            '09/16/2026 12:30',
            '1 BREAD         2.00',
            '1 EGGS          4.00',
            '1 RICE          5.00',
            'SUBTOTAL       14.00',
            'TAX             0.00',
            'TOTAL          14.00',
        ],
    ]:
        picture = Image.new('RGB', (900, 850), 'white')
        draw = ImageDraw.Draw(picture)
        font = ImageFont.load_default(size=32)
        for i, line in enumerate(lines):
            draw.text((60, 50 + i * 80), line, font=font, fill='black')
        output = io.BytesIO()
        picture.save(output, format='JPEG', quality=95)
        pages.append(output.getvalue())
    return [pages]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scenario', choices=['parallel', 'multi', 'logo'], required=True)
    parser.add_argument('--url', required=True)
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--data-directory', type=Path, required=True)
    args = parser.parse_args()
    key = args.key_file.read_text().strip()
    base = args.url.rstrip('/')
    request = urllib.request.Request(base + '/v1/models', headers={'Authorization': 'Bearer ' + key})
    with urllib.request.urlopen(request, timeout=15) as response:
        model = json.load(response)['data'][0]['id']

    def call(component, operation, value):
        body = json.dumps({'request_key': str(uuid.uuid4()), 'input': value}).encode()
        req = urllib.request.Request(
            f'{base}/api/v1/{component}/{operation}',
            data=body,
            headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'},
        )
        with urllib.request.urlopen(req, timeout=15) as reply:
            return json.load(reply)['data']

    owned, jobs = [], []
    try:
        for photos in photo_groups(args.scenario):
            now = int(time.time() * 1000)
            r = call(
                'receipts',
                'save',
                {
                    'receipt': {
                        'id': str(uuid.uuid4()),
                        'store': '' if args.scenario == 'logo' else 'AUTOTEST ASYNC PROBE',
                        'branch': '',
                        'address': '',
                        'country': 'US',
                        'currency': 'USD',
                        'timeSource': 'estimated_instant',
                        'rawTime': '',
                        'totalSource': 'user_entered',
                        'occurredAt': now,
                        'createdAt': now,
                        'revision': 0,
                        'totalMinor': 0,
                        'posted': False,
                        'lines': [],
                    }
                },
            )
            owned.append(r['id'])
            uploaded = r
            for photo in photos:
                boundary = 'probe-' + uuid.uuid4().hex
                metadata = json.dumps(
                    {
                        'request_key': str(uuid.uuid4()),
                        'input': {
                            'receipt_id': r['id'],
                            'expected_version': uploaded['revision'],
                            'captured_at_utc_ms': now,
                        },
                    }
                )
                body = (
                    (
                        f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n{metadata}\r\n'
                        f'--{boundary}\r\nContent-Disposition: form-data; name="photo"; filename="probe.jpg"\r\nContent-Type: image/jpeg\r\n\r\n'
                    ).encode()
                    + photo
                    + f'\r\n--{boundary}--\r\n'.encode()
                )
                req = urllib.request.Request(
                    base + '/api/v1/images/upload',
                    data=body,
                    headers={
                        'Authorization': 'Bearer ' + key,
                        'Content-Type': 'multipart/form-data; boundary=' + boundary,
                    },
                )
                with urllib.request.urlopen(req, timeout=30) as reply:
                    uploaded = json.load(reply)['data']['receipt']
            started = time.monotonic()
            job = call(
                'recognition',
                'start',
                {'receipt_id': r['id'], 'expected_version': uploaded['revision'], 'zone': 'America/New_York'},
            )
            duration = time.monotonic() - started
            assert duration < 2, f'Submission blocked for {duration:.2f}s'
            jobs.append(job['job_id'])
            print(f'Job accepted in {duration * 1000:.0f} ms', flush=True)
        # Observe from the test harness only; never request apply. The backend owns completion.
        deadline = time.monotonic() + 600
        seen = set()
        while time.monotonic() < deadline:
            states = [call('recognition', 'get', {'id': job})['status'] for job in jobs]
            seen.add(tuple(states))
            assert not any(state in ['failed', 'cancelled', 'unknown'] for state in states), states
            if all(state == 'applied' for state in states):
                break
            started = time.monotonic()
            call('receipts', 'get', {'id': owned[0]})
            assert time.monotonic() - started < 2, 'Receipt query blocked by inference'
            time.sleep(2)
        else:
            raise AssertionError('Recognition did not finish')
        if args.scenario == 'parallel':
            assert ('running', 'queued') in seen, seen
            assert ('running', 'running') not in seen, seen
        for rid in owned:
            receipt = call('receipts', 'get', {'id': rid})
            assert receipt['lines'] and receipt['revision'] > 2 and not receipt['posted']
            if args.scenario == 'logo':
                if receipt['store'] != 'Costco':
                    print('Logo diagnostics:', call('logos', 'match', {'receipt_id': rid}), flush=True)
                    for run in call('recognition', 'runs', {}):
                        if run['receipt_id'] == rid and run['status'] == 'succeeded':
                            result = json.loads((args.data_directory / 'recognition' / (run['run_id'] + '.json')).read_text())
                            print('Logo box:', result.get('logo_inference', {}).get('evidence'), flush=True)
                assert receipt['store'] == 'Costco', receipt['store']
            if args.scenario == 'multi':
                assert len(call('images', 'list', {'receipt_id': rid})) == 2
                assert len(receipt['lines']) == 5, receipt
                assert receipt['totalMinor'] == 1400 and receipt['summary']['difference'] == 0, receipt
                products = [line for line in receipt['lines'] if line['kind'] == 'product']
                assert [line['rawName'].removeprefix('1 ') for line in products] == [
                    'MILK',
                    'BREAD',
                    'EGGS',
                    'RICE',
                ], receipt

        runs = [
            run
            for run in call('recognition', 'runs', {})
            if run['receipt_id'] in owned and run['status'] == 'succeeded'
        ]
        assert len(runs) == len(owned), runs
        for run in runs:
            result = json.loads((args.data_directory / 'recognition' / (run['run_id'] + '.json')).read_text())
            assert result['receipt_parsing']['version'] == 'qwen3.8-ninfer-v1'
            assert result['receipt_parsing']['image_count'] == (2 if args.scenario == 'multi' else 1)
        with urllib.request.urlopen(base + '/android-update.json') as reply:
            manifest = json.load(reply)
        with urllib.request.urlopen(base + '/receipt_master.apk') as reply:
            digest = hashlib.sha256(reply.read()).hexdigest()
        assert digest == manifest['variants']['arm64-v8a']['sha256']
        print(
            f'PASS: {args.scenario}, automatic drafts, Qwen vision and store prompts, responsive API; APK build {manifest["build_number"]}',
            flush=True,
        )
    finally:
        for rid in owned:
            current = call('receipts', 'get', {'id': rid})
            call('receipts', 'purge', {'id': rid, 'expected_version': current['revision']})


if __name__ == '__main__':
    main()
