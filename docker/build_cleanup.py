"""Clean only recognized Receipt Master outputs after successful export."""

import argparse
import fcntl
import hashlib
import os
import shutil
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path

ANDROID = [
    'build/android-staging',
    'build/android-candidate.json',
    'build/flutter',
    'build/mobile/receipt-master-debug.apk',
    'build/ios-recognition-checks.Dockerfile',
    'build/ios-recognition-checks.Dockerfile.dockerignore',
]
NATIVE = [
    'src/shared/.dart_tool',
    'src/shared/build',
    'src/shared/.flutter-plugins-dependencies',
    'tests/shared/.dart_tool',
    'tests/shared/build',
    'tests/shared/.flutter-plugins-dependencies',
]
RUST = ['build/backend_api/target', 'src/backend_api/target']


def stream_digest(handle):
    digest = hashlib.sha256()
    for block in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(block)
    return digest.hexdigest()


def owned(root, relative):
    path = root / relative
    for item in [path, *path.parents]:
        if item == root:
            break
        if item.is_symlink():
            raise ValueError(f'Refusing a symlink in cleanup path: {relative}')
    if not path.is_relative_to(root):
        raise ValueError('Cleanup path is outside the repository')
    return path


def validate(root, work):
    if not root.is_absolute() or root.resolve() != root:
        raise ValueError('The repository must be a canonical absolute path')
    if work.parent != root / 'build' or not work.name.startswith('work.'):
        raise ValueError('The work directory does not belong to this build')
    owned(root, str(work.relative_to(root)))
    if not work.is_dir():
        raise ValueError('The build work directory is absent')


def remove(path):
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def clean(root, work, component, owner):
    validate(root, work)
    relatives = list(ANDROID) if component in {'android', 'docker', 'ios'} else []
    if component in {'ios', 'android', 'docker'}:
        relatives += NATIVE
    if component == 'docker':
        for directory in ['docker', 'tests', 'src']:
            for path in (root / directory).rglob('__pycache__'):
                relatives += [str(path.relative_to(root))]
    with ExitStack() as locks:
        if component == 'docker':
            for relative in RUST:
                target = owned(root, relative)
                if not target.exists():
                    continue
                tag = target / 'CACHEDIR.TAG'
                if not tag.is_file() or not tag.read_text().startswith('Signature: 8a477f597d28d172789f06886806bc55'):
                    raise ValueError(f'Unrecognized Rust cache: {relative}')
                for profile in ['debug', 'release']:
                    path = target / profile / '.cargo-lock'
                    if path.exists():
                        handle = locks.enter_context(path.open('r+b'))
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                relatives += [relative]
        paths = [owned(root, relative) for relative in relatives]
        for path in paths:
            remove(path)
        if component in {'android', 'docker'}:
            target = root / 'build/mobile'
            if target.exists():
                sums = ''
                for path in sorted(target.glob('*.apk')):
                    with path.open('rb') as handle:
                        sums += f'{stream_digest(handle)}  {path.name}\n'
                (target / 'SHA256SUMS').write_text(sums)
        if owner:
            remove(work)
    print(f'Cleaned {component} temporary outputs and build caches')


def export_web(source, target):
    if not (source / 'index.html').is_file() or target.is_symlink():
        raise ValueError('Invalid Web artifact export')
    previous = source.parent / 'web-previous'
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.rename(previous)
    try:
        source.rename(target)
    except OSError:
        if previous.exists():
            previous.rename(target)
        raise
    remove(previous)


def export_ios(source, target):
    if not source.is_dir():
        raise ValueError('The compiled iOS application is absent')
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.candidate.zip')
    shutil.make_archive(str(temporary.with_suffix('')), 'zip', source.parent, source.name)
    temporary.replace(target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['validate', 'clean', 'export-ios', 'export-web'])
    parser.add_argument('--root', type=Path)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--component', choices=['docker', 'android', 'web', 'ios', 'prepare'])
    parser.add_argument('--owner', type=int, choices=[0, 1])
    parser.add_argument('--source', type=Path)
    parser.add_argument('--target', type=Path)
    args = parser.parse_args()
    if args.action == 'export-web':
        export_web(args.source, args.target)
    elif args.action == 'export-ios':
        export_ios(args.source, args.target)
    elif args.action == 'validate':
        validate(args.root, args.work)
    else:
        try:
            clean(args.root, args.work, args.component, args.owner)
        except PermissionError:
            if sys.platform != 'linux' or os.geteuid() == 0:
                raise
            # Old Docker-based tests can leave root-owned generated files.
            # Reuse the same path guards inside a disposable cleanup container.
            validate(args.root, args.work)
            subprocess.run(
                [
                    'docker',
                    'run',
                    '--rm',
                    '--user',
                    '0:0',
                    '--mount',
                    f'type=bind,source={args.root},target={args.root}',
                    'python:3.12-slim',
                    'python3',
                    str(Path(__file__).resolve()),
                    *sys.argv[1:],
                ],
                check=True,
            )


if __name__ == '__main__':
    main()
