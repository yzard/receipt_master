"""Read-only logo retrieval benchmark through the running OCR queue.

Run alongside logo_variants.py inside the OCR container. Reference labels are hidden
from Qwen: it selects an image ID or rejects all candidates. Production is unchanged.
"""

import argparse
import base64
import hashlib
import io
import json
import random
import time
import urllib.request
from pathlib import Path

import numpy as np
from logo_variants import variants
from PIL import Image, ImageDraw


def encode(path, longest=None):
    if longest is None:
        return base64.b64encode(path.read_bytes()).decode()
    with Image.open(path) as opened:
        image = opened.convert('RGB')
        image.thumbnail((longest, longest), Image.Resampling.LANCZOS)
        data = io.BytesIO()
        image.save(data, format='PNG')
    return base64.b64encode(data.getvalue()).decode()


def post(url, route, value):
    request = urllib.request.Request(
        url + route, data=json.dumps(value).encode(), headers={'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--url', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--prompt-file', type=Path, required=True)
    parser.add_argument('--max-output-tokens', type=int, required=True)
    args = parser.parse_args()
    prompt = args.prompt_file.read_text()
    assert prompt.strip() and args.max_output_tokens > 0
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((args.input / 'manifest.json').read_text())
    references, cases = manifest['references'], manifest['cases']
    for sample in references + cases:
        assert hashlib.sha256((args.input / sample['path']).read_bytes()).hexdigest() == sample['sha256']
    # Controlled perturbations of held-out crops, explicitly distinct from independent photos.
    for name in ['Target', 'skyFOODS', 'Hualian']:
        sample = next(c for c in cases if c['expected'] == name)
        image = np.asarray(Image.open(args.input / sample['path']).convert('RGB'))
        for kind, transformed in variants(image).items():
            if kind == 'faint':
                continue
            path = f'images/{sample["id"]}-{kind}.png'
            Image.fromarray(transformed).save(args.input / path)
            cases.append({'id': sample['id'] + '-' + kind, 'kind': 'synthetic_' + kind, 'expected': name, 'path': path})
    for name in ['Target', 'Hualian']:
        sample = next(c for c in cases if c['expected'] == name)
        cases.append(
            {**sample, 'id': sample['id'] + '-absent', 'kind': 'missing_reference', 'expected': None, 'exclude': name}
        )
    for name in ['blank', 'unregistered_text']:
        image = Image.new('RGB', (768, 320), 'white')
        if name == 'unregistered_text':
            from PIL import ImageFont

            draw = ImageDraw.Draw(image)
            draw.text((80, 90), 'FRESH GOODS', fill='black', font=ImageFont.load_default(size=64))
        path = f'images/{name}.png'
        image.save(args.input / path)
        cases.append({'id': name, 'kind': 'negative_control', 'expected': None, 'path': path})
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    (args.output / 'prompt.txt').write_text(prompt)
    labels = {r['id']: r['name'] for r in references}
    results = []
    for index, case in enumerate(cases):
        refs = [r for r in references if r['name'] != case.get('exclude')]
        random.Random(42 + index).shuffle(refs)
        query = args.input / case['path']
        content = [
            {'type': 'text', 'text': 'QUERY image:'},
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + encode(query, 768)}},
        ]
        for reference in refs:
            content.extend(
                [
                    {'type': 'text', 'text': 'REFERENCE ' + reference['id'] + ':'},
                    {
                        'type': 'image_url',
                        'image_url': {'url': 'data:image/png;base64,' + encode(args.input / reference['path'], 768)},
                    },
                ]
            )
        started = time.monotonic()
        raw = post(
            args.url,
            '/v1/chat/completions',
            {
                'model': args.model,
                'messages': [{'role': 'system', 'content': prompt}, {'role': 'user', 'content': content}],
                'temperature': 0,
                'seed': 42,
                'max_tokens': args.max_output_tokens,
                'response_format': {'type': 'text'},
                'chat_template_kwargs': {'enable_thinking': True},
            },
        )
        qwen_seconds = time.monotonic() - started
        (args.output / (case['id'] + '.json')).write_text(json.dumps(raw, ensure_ascii=False, indent=2))
        valid, selected, error = False, None, None
        try:
            choice = raw['choices'][0]
            assert choice['finish_reason'] == 'stop', choice['finish_reason']
            text = choice['message']['content'].strip()
            if text.startswith('```json\n') and text.endswith('\n```'):
                text = text[8:-4]
            prediction = json.loads(text)
            assert set(prediction) == {'reference_id'}, prediction
            identity = prediction['reference_id']
            assert identity is None or identity in {r['id'] for r in refs}, prediction
            selected = labels[identity] if identity else None
            valid = True
        except (AssertionError, ValueError, KeyError, TypeError) as exc:
            error = str(exc)
        result = {
            **case,
            'qwen': selected,
            'valid': valid,
            'error': error,
            'qwen_correct': valid and selected == case['expected'],
            'qwen_seconds': qwen_seconds,
            'reference_order': [r['id'] for r in refs],
            'usage': raw.get('usage'),
        }
        results.append(result)
        (args.output / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(
            f'{index+1}/{len(cases)} {case["kind"]} {case["id"][:20]} expected={case["expected"]} Qwen={selected} valid={valid} {qwen_seconds:.1f}s',
            flush=True,
        )


if __name__ == '__main__':
    main()
