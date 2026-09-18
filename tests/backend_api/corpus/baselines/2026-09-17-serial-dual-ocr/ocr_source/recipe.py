"""Pinned Unlimited-OCR text/layout inference on loopback."""
from pathlib import Path
from config import EngineConfig


def command_for(config: EngineConfig) -> list[str]:
    if not Path(config.path, "config.json").is_file():
        raise ValueError("Unlimited-OCR weights must be included in the image")
    return [
        "vllm", "serve", config.path, "--served-model-name", config.model,
        "--host", "127.0.0.1", "--port", str(config.port), "--dtype", "bfloat16",
        "--gpu-memory-utilization", str(config.memory_fraction),
        "--max-model-len", str(config.context_length),
        "--max-num-batched-tokens", str(config.max_batched_tokens),
        "--max-num-seqs", str(config.max_sequences),
        "--trust-remote-code", "--enforce-eager", "--no-enable-log-requests",
        "--logits_processors", "vllm.model_executor.models.unlimited_ocr:NGramPerReqLogitsProcessor",
        "--no-enable-prefix-caching", "--mm-processor-cache-gb", "0",
    ]
