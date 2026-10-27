"""Preserve only the pinned Qwen model image as a cross-project OCI input."""

import argparse
import fcntl
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def stream_digest(handle):
    digest = hashlib.sha256()
    for block in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(block)
    return digest.hexdigest()


def command(*args):
    return subprocess.check_output(['docker', *args], text=True)


def contract(dockerfile):
    match = re.search(r'(?m)^FROM ([^\n]+) AS qwen-model\n(ADD[^\n]+)\n(ADD[^\n]+)', dockerfile.read_text())
    if not match:
        raise ValueError('Missing pinned qwen-model stage')
    stage = match.group(0)
    assets = re.findall(r'--checksum=sha256:([a-f0-9]{64}) (https://\S+) (/models/\S+)', stage)
    if len(assets) != 2 or not assets[0][2].endswith('.ninfer'):
        raise ValueError('The shared model stage must contain exactly two pinned assets')
    return stage, assets


def digest(path):
    with path.open('rb') as handle:
        return stream_digest(handle)


def blob(layout, value):
    data = json.dumps(value, separators=(',', ':')).encode()
    sha = hashlib.sha256(data).hexdigest()
    (layout / 'blobs/sha256' / sha).write_bytes(data)
    return {'digest': 'sha256:' + sha, 'size': len(data)}


def asset_instruction(instruction, url, destination):
    return instruction == f'ADD --chmod=644 {url} {destination} # buildkit' or (
        instruction
        in {f'COPY --link {destination} {destination} # buildkit', f'COPY {destination} {destination} # buildkit'}
    )


def boundary(config, assets):
    whole = [
        i
        for i, entry in enumerate(config['history'])
        if entry.get('created_by') in {'COPY / / # buildkit', 'COPY --link / / # buildkit'}
    ]
    if whole and ((config.get('config') or {}).get('Labels') or {}).get('org.shared-model.sha256') == assets[0][0]:
        if len(whole) != 1:
            raise ValueError('Ambiguous model tree in local image')
        start = sum(not entry.get('empty_layer', False) for entry in config['history'][: whole[0]])
        return [config['history'][whole[0]]], start, 1
    indices = []
    for _, url, destination in assets:
        found = [
            i
            for i, entry in enumerate(config['history'])
            if asset_instruction(entry.get('created_by', ''), url, destination)
        ]
        if len(found) != 1:
            raise ValueError('The local image does not contain the pinned model stage')
        indices += found
    if indices[0] >= indices[1]:
        raise ValueError('Invalid model layer order')
    start = sum(not entry.get('empty_layer', False) for entry in config['history'][: indices[0]])
    history = config['history'][indices[0] : indices[-1] + 1]
    count = sum(not entry.get('empty_layer', False) for entry in history)
    return history, start, count


def local_source(assets):
    seen = set()
    for image in command('image', 'ls', '--quiet', '--no-trunc').splitlines():
        if image in seen:
            continue
        seen.add(image)
        history = command('image', 'history', '--no-trunc', '--format', '{{.CreatedBy}}', image)
        if all(
            any(asset_instruction(line, url, destination) for line in history.splitlines())
            for _, url, destination in assets
        ):
            return image
        if any(line in {'COPY / / # buildkit', 'COPY --link / / # buildkit'} for line in history.splitlines()):
            config = json.loads(command('image', 'inspect', image))[0]
            if ((config.get('Config') or {}).get('Labels') or {}).get('org.shared-model.sha256') == assets[0][0]:
                return image
    return None


def export_local(image, layout, assets, selector=None):
    print(f'Reusing local image layers from {image}; no download', file=sys.stderr)
    files = {}
    metadata = {}
    process = subprocess.Popen(['docker', 'image', 'save', image], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for entry in archive:
                if not entry.isfile():
                    continue
                source = archive.extractfile(entry)
                if entry.name.endswith('.json') or (
                    entry.name.startswith('blobs/sha256/') and entry.size < 2 * 1024 * 1024
                ):
                    data = source.read()
                    try:
                        metadata[entry.name] = json.loads(data)
                        continue
                    except (ValueError, UnicodeDecodeError):
                        path = layout / ('layer-' + str(len(files)))
                        path.write_bytes(data)
                        files[entry.name] = path
                elif entry.name.endswith('layer.tar') or entry.name.startswith('blobs/sha256/'):
                    path = layout / ('layer-' + str(len(files)))
                    with path.open('wb') as output:
                        shutil.copyfileobj(source, output, length=1024 * 1024)
                    files[entry.name] = path
        if process.wait() != 0:
            raise RuntimeError('Docker image export failed')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    manifest = metadata['manifest.json'][0]
    config = metadata[manifest['Config']]
    history, start, count = selector(config) if selector else boundary(config, assets)
    selected = manifest['Layers'][start : start + count]
    layers = []
    for filename, diff in zip(selected, config['rootfs']['diff_ids'][start : start + count], strict=True):
        path = files[filename]
        with path.open('rb') as handle:
            compressed = handle.read(2) == b'\x1f\x8b'
        if compressed:
            unpacked = path.with_suffix('.tar')
            with gzip.open(path, 'rb') as source, unpacked.open('wb') as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            path.unlink()
            path = unpacked
        sha = digest(path)
        if 'sha256:' + sha != diff:
            raise ValueError('Exported model layer differs from its local image')
        destination = layout / 'blobs/sha256' / sha
        path.replace(destination)
        layers.append(
            {'mediaType': 'application/vnd.oci.image.layer.v1.tar', 'digest': diff, 'size': destination.stat().st_size}
        )
    for path in files.values():
        path.unlink(missing_ok=True)
    config['rootfs']['diff_ids'] = config['rootfs']['diff_ids'][start : start + count]
    config['history'] = history
    if selector is None:
        config['config'] = {'Labels': {'org.shared-model.sha256': assets[0][0]}}
    config.pop('container_config', None)
    descriptor = blob(layout, config)
    descriptor['mediaType'] = 'application/vnd.oci.image.config.v1+json'
    manifest = {
        'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': descriptor,
        'layers': layers,
    }
    descriptor = blob(layout, manifest)
    descriptor.update(mediaType=manifest['mediaType'], annotations={'org.opencontainers.image.ref.name': 'qwen-model'})
    (layout / 'index.json').write_text(json.dumps({'schemaVersion': 2, 'manifests': [descriptor]}))
    (layout / 'oci-layout').write_text('{"imageLayoutVersion":"1.0.0"}')


def inspect_layout(layout, assets, full=False):
    index = json.loads((layout / 'index.json').read_text())
    descriptor = next(item for item in index['manifests'] if item.get('platform', {}).get('os') != 'unknown')
    manifest = json.loads((layout / 'blobs/sha256' / descriptor['digest'].split(':')[1]).read_text())
    config = json.loads((layout / 'blobs/sha256' / manifest['config']['digest'].split(':')[1]).read_text())
    if (
        len(manifest['layers']) not in {1, 2}
        or len(config['rootfs']['diff_ids']) != len(manifest['layers'])
        or config['config'].get('Labels', {}).get('org.shared-model.sha256') != assets[0][0]
    ):
        raise ValueError('The persistent model cache must contain only model and license layers')
    for item in [descriptor, manifest['config'], *manifest['layers']]:
        path = layout / 'blobs/sha256' / item['digest'].split(':')[1]
        if path.stat().st_size != item['size'] or (full and 'sha256:' + digest(path) != item['digest']):
            raise ValueError('Corrupt shared model cache')
    if full:
        expected = {destination.lstrip('/'): sha for sha, _, destination in assets}
        found = set()
        for item in manifest['layers'][-2:]:
            path = layout / 'blobs/sha256' / item['digest'].split(':')[1]
            with tarfile.open(path, mode='r|*') as archive:
                for member in archive:
                    name = member.name.lstrip('./')
                    if name not in expected:
                        if not member.isdir() or name not in {'', 'models'}:
                            raise ValueError('The model cache contains non-model files')
                        continue
                    if stream_digest(archive.extractfile(member)) != expected[name]:
                        raise ValueError('The local model asset has the wrong checksum')
                    found.add(name)
        if found != expected.keys():
            raise ValueError('The model asset is absent')
    return descriptor['digest'], config['rootfs']['diff_ids']


def prepare(root, builder, cache_root):
    stage, assets = contract(root / 'docker/backend_ocr.Dockerfile')
    cache_root.mkdir(parents=True, exist_ok=True)
    if cache_root.is_symlink():
        raise ValueError('The shared model cache cannot be a symlink')
    with (cache_root / 'model.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        layout = cache_root / 'model'
        if not layout.exists():
            # This work contains only model layers. Keep failed work for diagnosis.
            staging = Path(tempfile.mkdtemp(prefix='model-work.', dir=cache_root))
            (staging / 'blobs/sha256').mkdir(parents=True)
            source = local_source(assets)
            if source:
                export_local(source, staging, assets)
            else:
                print('No pinned local Qwen model found; downloading the model stage once', file=sys.stderr)
                subprocess.run(
                    [
                        'docker',
                        'buildx',
                        'build',
                        '--builder',
                        builder,
                        '--platform',
                        'linux/amd64',
                        '--target',
                        'qwen-model',
                        '--provenance=false',
                        '--output',
                        f'type=oci,dest={staging},tar=false,compression=uncompressed',
                        '--file',
                        str(root / 'docker/backend_ocr.Dockerfile'),
                        str(root),
                    ],
                    check=True,
                    stdout=sys.stderr,
                )
            inspect_layout(staging, assets, full=True)
            staging.replace(layout)
        manifest, _ = inspect_layout(layout, assets)
        print(f'Reusing shared Qwen model layout {layout}; no model download', file=sys.stderr)
    print(f'qwen-model=oci-layout://{layout}@{manifest}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'verify'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--builder')
    parser.add_argument(
        '--cache-root',
        type=Path,
        default=Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))
        / 'shared-model-layers/qwen3.8-27b-nvfp4-ninfer-f0b43ad4',
    )
    parser.add_argument('--image')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.root, args.builder, args.cache_root)
    else:
        stage, assets = contract(args.root / 'docker/backend_ocr.Dockerfile')
        layout = args.cache_root / 'model'
        _, expected = inspect_layout(layout, assets)
        result = command('run', '--rm', '--entrypoint', 'sha256sum', args.image, *[item[2] for item in assets])
        if [line.split()[0] for line in result.splitlines()] != [item[0] for item in assets]:
            raise ValueError('The OCR image has incorrect shared model assets')
        print('Verified image-embedded shared Qwen model and license')


if __name__ == '__main__':
    main()
