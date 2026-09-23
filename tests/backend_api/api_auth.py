"""Read the playground client key from its persistent TOML configuration."""

import tomllib
from pathlib import Path


def client_key(config: Path) -> str:
    key = tomllib.loads(config.read_text())['general']['api_key'].strip()
    if len(key) < 24:
        raise ValueError('Invalid client API key in backend_api.toml')
    return key
