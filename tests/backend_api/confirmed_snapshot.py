"""Freeze all posted receipts through read-only API operations for model comparison."""

import argparse
import hashlib
import json
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', required=True)
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fallback-zone', required=True)
    args = parser.parse_args()
    if urllib.parse.urlparse(args.url).hostname not in {'127.0.0.1', 'localhost', '::1'}:
        raise ValueError('Use the local playground')
    ZoneInfo(args.fallback_zone)
    if (args.output / 'snapshot.json').exists():
        raise ValueError('Snapshot already exists; use a new directory')
    key = args.key_file.read_text().strip()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'images').mkdir(exist_ok=True)

    def read(path, value=None):
        request = urllib.request.Request(
            args.url.rstrip('/') + path,
            data=None if value is None else json.dumps({'input': value}).encode(),
            headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()

    def call(component, operation, value):
        return json.loads(read(f'/api/v1/{component}/{operation}', value))['data']

    def posted_ids():
        cursor, ids = None, []
        while True:
            page = call('receipts', 'list', {'limit': 200, 'cursor': cursor})
            ids.extend(r['receipt_id'] for r in page['items'] if r['status'] == 'posted')
            cursor = page['next_cursor']
            if cursor is None:
                return ids

    ids = posted_ids()
    cases = []
    for receipt_id in ids:
        receipt = call('receipts', 'get', {'id': receipt_id})
        if not receipt['posted']:
            raise ValueError('Receipt changed while snapshotting')
        photos = call('images', 'list', {'receipt_id': receipt_id})
        jobs = call('recognition', 'list', {'receipt_id': receipt_id})
        zone = next(
            (
                json.loads(j['result_json']).get('zone')
                for j in jobs
                if j.get('result_json') and json.loads(j['result_json']).get('zone')
            ),
            None,
        )
        case = {
            'id': receipt_id,
            'expected': receipt,
            'zone': zone or args.fallback_zone,
            'zone_source': 'recognition_job' if zone else 'explicit_fallback',
            'images': [],
        }
        for i, photo in enumerate(photos):
            data = read('/api/v1/media/' + photo['media_id'])
            digest = hashlib.sha256(data).hexdigest()
            if digest != photo['content_sha256']:
                raise ValueError('Image checksum changed')
            extension = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp'}[photo['mime']]
            path = f'images/{receipt_id}-{i}.{extension}'
            (args.output / path).write_bytes(data)
            case['images'].append(
                {
                    'path': path,
                    'sha256': digest,
                    'mime': photo['mime'],
                    'image_id': photo['image_id'],
                    'original_blob_id': photo['original_blob_id'],
                    'current_blob_id': photo['current_blob_id'],
                }
            )
        current = call('receipts', 'get', {'id': receipt_id})
        if current != receipt:
            raise ValueError('Receipt changed while snapshotting')
        cases.append(case)
        print(receipt_id, receipt['store'], len(photos), 'photos', len(receipt['lines']), 'lines', flush=True)
    if set(posted_ids()) != set(ids):
        raise ValueError('Confirmed receipt selection changed; take a fresh snapshot')
    snapshot = {
        'captured_at_utc': datetime.now(timezone.utc).isoformat(),
        'selection': 'all non-deleted posted receipts',
        'image_selection': 'all current non-deleted photos, in saved order, including saved rotations',
        'cases': cases,
    }
    (args.output / 'snapshot.json').write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + '\n')
    print(f'Saved {len(cases)} confirmed receipts; {sum(not c["images"] for c in cases)} without photos.')


if __name__ == '__main__':
    main()
