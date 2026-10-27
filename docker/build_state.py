"""Reuse verified final outputs without retaining compiler or dependency caches."""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

EXCLUDED = {
    '.git',
    '.dart_tool',
    '.gradle',
    '.kotlin',
    '.cxx',
    'build',
    'node_modules',
    '__pycache__',
    'Pods',
    '.symlinks',
    'ephemeral',
}
GENERATED = {
    'local.properties',
    'key.properties',
    '.flutter-plugins-dependencies',
    'GeneratedPluginRegistrant.java',
    'Generated.xcconfig',
    'flutter_export_environment.sh',
}


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def files(root, paths, filtered=True):
    found = {}
    for relative in paths:
        path = root / relative
        if not path.exists():
            found[relative] = None
            continue
        for item in sorted(path.rglob('*')) if path.is_dir() else [path]:
            if not item.is_file():
                continue
            parts = item.relative_to(path if path.is_dir() else path.parent).parts
            if filtered and (
                EXCLUDED.intersection(parts) or item.name in GENERATED or item.suffix in {'.jks', '.keystore'}
            ):
                continue
            found[str(item.relative_to(root))] = digest(item)
    return found


def fingerprint(root, inputs, values=()):
    payload = {'files': files(root, inputs), 'values': list(values)}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def image_exists(image):
    result = subprocess.run(['docker', 'image', 'inspect', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def reusable(root, target, key, outputs):
    path = root / 'build/state' / (target + '.json')
    if not path.is_file():
        return None
    state = json.loads(path.read_text())
    if state['fingerprint'] != key:
        return None
    current = files(root, outputs, filtered=False)
    if any(value is None for value in current.values()) or current != state['outputs']:
        return None
    if state.get('image') and not image_exists(state['image']):
        return None
    return state.get('image') or 'reusable'


def record(root, target, key, outputs, image=None):
    current = files(root, outputs, filtered=False)
    if any(value is None for value in current.values()):
        raise ValueError('Cannot record an absent build output')
    if image and not image_exists(image):
        raise ValueError('Cannot record an absent image')
    path = root / 'build/state' / (target + '.json')
    path.parent.mkdir(parents=True, exist_ok=True)
    candidate = path.with_suffix('.candidate.json')
    candidate.write_text(json.dumps({'fingerprint': key, 'outputs': current, 'image': image}, indent=2) + '\n')
    candidate.replace(path)


def runtime_key(root):
    text = (root / 'docker/backend_ocr.Dockerfile').read_text()
    text = text.split('FROM ocr-runtime AS runtime')[0]
    start = text.index('FROM python:3.12-slim AS checks')
    end = text.index('# Keep this model stage identical')
    return hashlib.sha256((text[:start] + text[end:]).encode()).hexdigest()


def runtime_history(config):
    history = config['history']
    matches = [
        i
        for i, item in enumerate(history)
        if item.get('created_by') == 'COPY /checks-passed /app/checks-passed # buildkit'
    ]
    if len(matches) != 1:
        raise ValueError('Cannot locate the runtime boundary in the OCR image')
    stop = matches[0]
    return history[:stop], 0, sum(not item.get('empty_layer', False) for item in history[:stop])


def prepare_runtime(root, work, image, key):
    # Only the final image persists. Its dependency prefix is temporary build input.
    inspected = json.loads(subprocess.check_output(['docker', 'image', 'inspect', image], text=True))[0]
    if ((inspected.get('Config') or {}).get('Labels') or {}).get('org.receipt.runtime') != key:
        return
    from shared_qwen import export_local

    layout = Path(tempfile.mkdtemp(prefix='ocr-runtime.', dir=work))
    (layout / 'blobs/sha256').mkdir(parents=True)
    export_local(image, layout, [], selector=runtime_history)
    index = json.loads((layout / 'index.json').read_text())
    print(f'ocr-runtime=oci-layout://{layout}@{index["manifests"][0]["digest"]}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['fingerprint', 'probe', 'record', 'runtime-key', 'runtime'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--target')
    parser.add_argument('--key')
    parser.add_argument('--input', action='append', default=[])
    parser.add_argument('--value', action='append', default=[])
    parser.add_argument('--output', action='append', default=[])
    parser.add_argument('--image')
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    if args.action == 'fingerprint':
        print(fingerprint(args.root, args.input, args.value))
    elif args.action == 'probe':
        print(reusable(args.root, args.target, args.key, args.output) or '')
    elif args.action == 'record':
        record(args.root, args.target, args.key, args.output, args.image)
    elif args.action == 'runtime-key':
        print(runtime_key(args.root))
    else:
        prepare_runtime(args.root, args.work, args.image, args.key)


if __name__ == '__main__':
    main()
