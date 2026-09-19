"""Native NVFP4 inference on loopback; the container API serializes requests."""

from pathlib import Path

from config import EngineConfig


def command_for(config: EngineConfig) -> list[str]:
    if not Path(config.path).is_file():
        raise ValueError("NInfer model artifact must be included in the image")
    return [
        "ninfer-serve",
        config.path,
        "--model-id",
        config.model,
        "--host",
        "127.0.0.1",
        "--port",
        str(config.port),
        "--max-context",
        str(config.context_length),
        "--kv-capacity",
        str(config.context_length),
        "--max-concurrency",
        str(config.max_sequences),
        "--kv-dtype",
        "fp8",
        "--device-state-slots",
        "0",
        "--host-state-slots",
        "1",
        "--host-kv-mib",
        "512",
        "--spec",
        "mtp",
        "--draft-tokens",
        str(config.draft_tokens),
        "--lm-head-draft",
        "--vision",
        "--media-preprocess-threads",
        "4",
        "--max-request-mib",
        "128",
    ]
