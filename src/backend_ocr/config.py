"""Validated, explicit container configuration."""

import tomllib
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class EngineConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str
    model: str
    port: int = Field(gt=0, le=65535)
    memory_fraction: float = Field(gt=0, lt=1)
    context_length: int = Field(gt=0)
    max_images: int = Field(gt=0)
    max_batched_tokens: int = Field(gt=0)
    max_sequences: Literal[1]


class PaddleConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    python: str
    port: int = Field(gt=0, le=65535)
    detection_path: str
    recognition_path: str
    threads: int = Field(gt=0)


class ServerConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    port: int = Field(gt=0, le=65535)
    max_requests: Literal[1]
    timeout_seconds: int = Field(gt=0)
    logo_model_path: str
    engine: EngineConfig
    paddle: PaddleConfig

    @model_validator(mode="after")
    def ports_differ(self):
        if len({self.port, self.engine.port, self.paddle.port}) != 3:
            raise ValueError("Public and engine ports must differ")
        return self


def load_config(path: Path) -> ServerConfig:
    return ServerConfig.model_validate(tomllib.loads(path.read_text()))
