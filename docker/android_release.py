"""Select a monotonic Android build number and publish verified APKs atomically."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
        return result.hexdigest()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def inputs(root, bootstrap, signer):
    files = []
    excluded = {'.dart_tool', '.gradle', '.kotlin', '.cxx', 'build', 'ephemeral', '.git', '__pycache__'}
    excluded_names = {'local.properties', 'key.properties', 'GeneratedPluginRegistrant.java'}
    for directory in ['src/shared/lib', 'src/shared/resources', 'src/android']:
        for path in (root / directory).rglob('*'):
            if path.is_file() and not excluded.intersection(path.relative_to(root).parts) and path.name not in excluded_names and path.suffix not in {'.keystore', '.jks'}:
                files.append(path)
    files += [root / name for name in ['src/shared/pubspec.yaml', 'src/shared/pubspec.lock', 'docker/android.Dockerfile', 'docker/android.Dockerfile.dockerignore', 'docker/apply_mobile_defaults.py', 'docker/android_release.py', 'build_android.sh']]
    hasher = hashlib.sha256()
    for path in sorted(files):
        hasher.update(str(path.relative_to(root)).encode() + b'\0' + bytes.fromhex(digest(path)))
    hasher.update(bytes.fromhex(digest(bootstrap)))
    hasher.update(bytes.fromhex(digest(signer)))
    return hasher.hexdigest()


def choose(root, bootstrap, signer):
    state_path = root / 'playground/android-release-state.json'
    previous = json.loads(state_path.read_text()) if state_path.exists() else {}
    fingerprint = inputs(root, bootstrap, signer)
    number = previous.get('build_number', 9999)
    if previous.get('input_hash') != fingerprint:
        number += 1
    candidate = {'input_hash': fingerprint, 'build_number': number}
    atomic_json(root / 'build/android-candidate.json', candidate)
    print(number)


def describe(artifacts, aapt, number):
    variants = {}
    for abi, filename in [('arm64-v8a', 'receipt-master-arm64.apk'), ('x86_64', 'receipt-master-x86_64.apk')]:
        path = artifacts / filename
        info = subprocess.check_output([aapt, 'dump', 'badging', str(path)], text=True)
        package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", info)
        if not package or package[1] != 'com.receiptmaster.receipt_master':
            raise ValueError('Invalid APK package metadata')
        sha = digest(path)
        variants[abi] = {'package_name': package[1], 'version_code': int(package[2]), 'version_name': package[3], 'sha256': sha, 'bytes': path.stat().st_size, 'path': f'/updates/{sha}.apk', 'file': filename}
    atomic_json(artifacts / 'android-update.json', {'schema_version': 1, 'build_number': number, 'variants': variants})


def publish(root):
    state_path = root / 'playground/android-release-state.json'
    previous = json.loads(state_path.read_text()) if state_path.exists() else {}
    candidate_path = root / 'build/android-candidate.json'
    candidate = json.loads(candidate_path.read_text())
    staging = root / 'build/android-staging'
    manifest = json.loads((staging / 'android-update.json').read_text())
    hashes = {abi: info['sha256'] for abi, info in manifest['variants'].items()}
    for info in manifest['variants'].values():
        if digest(staging / info['file']) != info['sha256']:
            raise ValueError('APK hash does not match generated metadata')
    if previous.get('input_hash') == candidate['input_hash'] and previous.get('build_number') == candidate['build_number'] and previous.get('hashes') != hashes:
        candidate['build_number'] += 1
        atomic_json(candidate_path, candidate)
        print(candidate['build_number'])
        return
    target = root / 'build/mobile'
    updates = target / 'updates'
    updates.mkdir(parents=True, exist_ok=True)
    for info in manifest['variants'].values():
        destination = updates / (info['sha256'] + '.apk')
        if not destination.exists():
            tmp = destination.with_suffix('.tmp')
            shutil.copyfile(staging / info['file'], tmp)
            tmp.replace(destination)
        elif digest(destination) != info['sha256']:
            raise ValueError('Existing immutable APK is corrupt')
    for path in staging.iterdir():
        if path.is_file() and path.name != 'android-update.json':
            tmp = target / (path.name + '.tmp')
            shutil.copyfile(path, tmp)
            tmp.replace(target / path.name)
    shutil.copyfile(target / 'receipt-master-arm64.apk', target / 'receipt_master.apk.tmp')
    (target / 'receipt_master.apk.tmp').replace(target / 'receipt_master.apk')
    # Publish the manifest last: every referenced immutable APK already exists.
    atomic_json(target / 'android-update.json', manifest)
    atomic_json(state_path, dict(candidate, hashes=hashes))
    print('published')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['choose', 'describe', 'publish'])
    parser.add_argument('--root', type=Path)
    parser.add_argument('--bootstrap', type=Path)
    parser.add_argument('--signer', type=Path)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--aapt')
    parser.add_argument('--number', type=int)
    args = parser.parse_args()
    if args.action == 'choose':
        choose(args.root, args.bootstrap, args.signer)
    elif args.action == 'describe':
        describe(args.artifacts, args.aapt, args.number)
    else:
        publish(args.root)


if __name__ == '__main__':
    main()
