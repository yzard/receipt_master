"""Reject Android releases that cannot connect to their intended backend."""

import json
import sys
from pathlib import Path
from urllib.parse import urlparse


def validate(path: Path) -> None:
    config = json.loads(path.read_text())
    endpoint = config.get('endpoint')
    key = config.get('api_key')
    url = urlparse(endpoint) if isinstance(endpoint, str) else None
    if (
        url is None
        or url.scheme not in ('http', 'https')
        or not url.hostname
        or url.hostname in ('localhost', '127.0.0.1', '0.0.0.0')
        or url.username
        or url.password
        or not isinstance(key, str)
        or len(key.strip()) < 24
    ):
        raise ValueError('APK requires a phone-accessible backend URL and API key')


if __name__ == '__main__':
    try:
        validate(Path(sys.argv[1]))
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from exc
