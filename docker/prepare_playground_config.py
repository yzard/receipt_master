"""Install each service's config.toml in its own persistent data directory."""

import argparse
import json
import os
import secrets
import shutil
import tempfile
import tomllib
from pathlib import Path


def write_sections(path: Path, sections: dict) -> None:
    content = []
    for name, values in sections.items():
        content.append(f'[{name}]')
        content.extend(f'{key} = {json.dumps(value)}' for key, value in values.items())
        content.append('')
    with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        os.chmod(temporary, 0o600)
        output.write('\n'.join(content))
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def unique_key(label: str, values: list[str]) -> str:
    present = {value.strip() for value in values if value.strip()}
    if len(present) > 1:
        raise ValueError(f'{label} values differ; resolve before building')
    key = next(iter(present), secrets.token_urlsafe(32))
    if len(key) < 24:
        raise ValueError(f'{label} must have at least 24 characters')
    return key


def move_legacy_layout(root: Path, api_data: Path, ocr_data: Path) -> None:
    legacy = root / 'playground/data'
    if not legacy.exists():
        return
    destinations = {
        'backend_api.toml': api_data / 'config.toml',
        'backend_ocr.toml': ocr_data / 'config.toml',
    }
    nested = legacy / 'config'
    sources = list(legacy.iterdir())
    if nested.is_dir():
        sources.extend(nested.iterdir())
        sources.remove(nested)
    moves = [(source, destinations.get(source.name, api_data / source.name)) for source in sources]
    targets = set()
    for source, destination in moves:
        if destination in targets or destination.exists():
            raise ValueError(f'Conflicting legacy data at {destination}; resolve before building')
        targets.add(destination)
    for source, destination in moves:
        source.replace(destination)
    if nested.is_dir():
        nested.rmdir()
    legacy.rmdir()


def move_nested_data(service_root: Path) -> None:
    nested = service_root / 'data'
    if not nested.exists():
        return
    moves = [(source, service_root / source.name) for source in nested.iterdir()]
    for _, destination in moves:
        if destination.exists():
            raise ValueError(f'Conflicting nested data at {destination}; resolve before building')
    for source, destination in moves:
        source.replace(destination)
    nested.rmdir()


def prepare(root: Path) -> Path:
    api_data = root / 'playground/backend_api'
    ocr_data = root / 'playground/backend_ocr'
    api_data.mkdir(parents=True, exist_ok=True)
    # Legacy directories remain untouched: merging service configuration requires
    # an operator-selected shared endpoint, never the obsolete internal OCR key.
    if (root / 'playground/data').exists() or (api_data / 'data').exists():
        raise ValueError('Stop the services and run --migrate-only before preparing configuration')
    defaults = root / 'docker/defaults'
    api_path = api_data / 'config.toml'
    if not api_path.exists():
        api = tomllib.loads((defaults / 'backend_api.toml').read_text())
        api['general']['jwt_secret'] = secrets.token_urlsafe(32)
        write_sections(api_path, api)
    api = tomllib.loads(api_path.read_text())
    if 'ocr' in api or 'inference' not in api:
        raise ValueError('Migrate config.toml from [ocr] to [inference]; see docs/shared_inference.md. Existing data and credentials were not changed.')
    prompt = api_data / 'prompt.toml'
    if not prompt.exists():
        shutil.copyfile(defaults / 'prompt.toml', prompt)
    api_path.chmod(0o600)
    return api_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--migrate-only', action='store_true')
    args = parser.parse_args()
    if args.migrate_only:
        api_data = args.root / 'playground/backend_api'
        ocr_data = args.root / 'playground/backend_ocr'
        api_data.mkdir(parents=True, exist_ok=True)
        ocr_data.mkdir(parents=True, exist_ok=True)
        move_legacy_layout(args.root, api_data, ocr_data)
        move_nested_data(api_data)
        move_nested_data(ocr_data)
    else:
        print(prepare(args.root))
