"""Read-only local vision checks for three recent problem receipts; no database writes."""

import argparse
import base64
import concurrent.futures
import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from decimal import Decimal
from pathlib import Path

from api_auth import client_key

ROOT = Path(__file__).parent / 'corpus'


def differences(prediction, case):
    errors = []
    rows = prediction['lines']
    products = [r for r in rows if r['kind'] == 'product']
    discounts = [r for r in rows if r['kind'] == 'item_discount']
    if prediction['total'] is None or Decimal(prediction['total']) != Decimal(case['total']):
        errors.append('printed total')
    amounts = [None if r['amount'] is None else Decimal(r['amount']) for r in rows]
    for i, row in enumerate(rows):
        if row.get('amount_basis') == 'net_including_item_discounts' and amounts[i] is not None:
            linked = [j for j, d in enumerate(rows) if d['kind'] == 'item_discount' and d['discount_target_index'] == i]
            amounts[i] = (
                None if any(amounts[j] is None for j in linked) else amounts[i] - sum(amounts[j] for j in linked)
            )
    if any(a is None for a in amounts) or sum(amounts) != Decimal(case['total']):
        errors.append('sum of charges')
    if len(products) != case['product_count']:
        errors.append('product count')
    if Counter(r['amount'] for r in discounts) != Counter(case['discount_amounts']):
        errors.append('individual discounts')
    if case['product_skus'] and Counter(r['sku'] for r in products) != Counter(case['product_skus']):
        errors.append('product SKUs')
    for discount in discounts:
        target = discount['discount_target_index']
        if target is None or target >= len(rows) or rows[target]['kind'] != 'product':
            errors.append('discount target')
        elif discount['name'] != rows[target]['name']:
            errors.append('discount product name')
    if not any(r['kind'] == 'tax' for r in rows):
        errors.append('tax line')
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='http://127.0.0.1:5000')
    parser.add_argument('--config', type=Path)
    parser.add_argument('--output-directory', type=Path, required=True)
    parser.add_argument('--score-only', action='store_true')
    args = parser.parse_args()
    if urllib.parse.urlparse(args.url).hostname not in {'127.0.0.1', 'localhost', '::1'}:
        raise ValueError('This evaluator sends private photos only to the local playground')
    key = '' if args.score_only else client_key(args.config)
    model = None
    if not args.score_only:
        request = urllib.request.Request(
            args.url.rstrip('/') + '/v1/models', headers={'Authorization': 'Bearer ' + key}
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            model = json.load(response)['data'][0]['id']
    schema = json.loads(Path(__file__).with_name('receipt_schema.json').read_text())
    cases = json.loads((ROOT / 'vision/reported-cases.json').read_text())['cases']
    args.output_directory.mkdir(parents=True, exist_ok=True)

    def run(case):
        image = (ROOT / case['image']).read_bytes()
        assert hashlib.sha256(image).hexdigest() == case['sha256']
        destination = args.output_directory / (case['id'] + '.json')
        if args.score_only:
            report = json.loads(destination.read_text())
            assert report['sha256'] == case['sha256']
        else:
            content = [
                {
                    'type': 'text',
                    'text': 'Trusted application context: '
                    + json.dumps({'known_store': case['known_store'], 'country': 'US', 'currency': 'USD'}),
                },
                {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode()},
                },
            ]
            body = {
                'model': model,
                'receipt_context': {'known_store': case['known_store']},
                'messages': [{'role': 'user', 'content': content}],
                'response_format': {
                    'type': 'json_schema',
                    'json_schema': {'name': 'receipt', 'strict': True, 'schema': schema},
                },
            }
            request = urllib.request.Request(
                args.url.rstrip('/') + '/v1/chat/completions',
                data=json.dumps(body).encode(),
                headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'},
            )
            started = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=600) as response:
                    result = json.load(response)
            except urllib.error.HTTPError as error:
                result = {'error': json.loads(error.read())}
            report = {
                'id': case['id'],
                'sha256': case['sha256'],
                'duration_seconds': round(time.monotonic() - started, 2),
                'response': result,
            }
        response = report['response']
        report['errors'] = (
            differences(json.loads(response['choices'][0]['message']['content']), case)
            if 'choices' in response
            else ['inference failed']
        )
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(case['id'], report['errors'] or 'PASS', flush=True)
        return report

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        reports = list(pool.map(run, cases))
    if any(r['errors'] for r in reports):
        raise SystemExit('One or more receipts failed critical invariants; predictions preserved.')


if __name__ == '__main__':
    main()
