"""Install editable TOML files in /data and embed persistent service keys."""

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


def prepare(root: Path) -> Path:
    data = root / 'playground/data'
    data.mkdir(parents=True, exist_ok=True)
    defaults = root / 'docker/defaults'
    for name in ('backend_api.toml', 'backend_ocr.toml', 'prompt.toml'):
        destination = data / name
        nested = data / 'config' / name
        if nested.exists():
            if destination.exists():
                if nested.read_bytes() != destination.read_bytes():
                    raise ValueError(f'Nested and root {name} differ; resolve before building')
                nested.unlink()
            else:
                nested.replace(destination)
        if not destination.exists():
            shutil.copyfile(defaults / name, destination)

    api_path = data / 'backend_api.toml'
    ocr_path = data / 'backend_ocr.toml'
    api = tomllib.loads(api_path.read_text())
    ocr = tomllib.loads(ocr_path.read_text())
    old_ocr = api['ocr']
    old_keys = [data / 'api-key', data / 'config/api-key', root / 'playground/secrets/ocr-api-key']
    ocr_key_file = data / 'ocr-api-key'
    client_key = unique_key('Client API key', [api['general'].get('api_key', '')] +
                            [p.read_text() for p in old_keys if p.exists()])
    service_key = unique_key('OCR service API key',
                             [old_ocr.get('api_key', ''), ocr['general'].get('api_key', '')] +
                             ([ocr_key_file.read_text()] if ocr_key_file.exists() else []))
    if client_key == service_key:
        raise ValueError('Client and OCR service API keys must differ')

    original_api, original_ocr = api_path.read_text(), ocr_path.read_text()
    general = api['general']
    general.pop('api_key_file', None)
    general.pop('served_model', None)
    general['api_key'] = client_key
    general['repair_attempts'] = old_ocr.get('repair_attempts', general.get('repair_attempts', 1))
    api['ocr'] = {'url': old_ocr['url'], 'api_key': service_key}
    api.pop('pricing', None)
    api.pop('budget', None)

    ocr['general'].pop('api_key_file', None)
    ocr['general']['api_key'] = service_key
    engine = ocr['engine']
    engine['max_images'] = old_ocr.get('max_images', engine['max_images'])
    engine['receipt_output_tokens'] = old_ocr.get('output_tokens', engine.get('receipt_output_tokens', 8192))
    engine.setdefault('logo_output_tokens', 4096)
    engine['thinking'] = old_ocr.get('thinking', engine.get('thinking', True))
    engine.setdefault('temperature', 0)
    engine.setdefault('seed', 42)

    if tomllib.loads(original_api) != api:
        write_sections(api_path, {name: api[name] for name in ('general', 'logos', 'ocr')})
    if tomllib.loads(original_ocr) != ocr:
        write_sections(ocr_path, {name: ocr[name] for name in ('general', 'engine')})
    api_path.chmod(0o600)
    ocr_path.chmod(0o600)
    for path in (*old_keys, ocr_key_file):
        path.unlink(missing_ok=True)
    nested_dir = data / 'config'
    if nested_dir.exists() and not any(nested_dir.iterdir()):
        nested_dir.rmdir()
    return api_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    print(prepare(parser.parse_args().root))
