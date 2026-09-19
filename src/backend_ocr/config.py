"""Explicit single-engine NInfer container configuration."""

import tomllib
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class EngineConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str
    model: str
    port: int = Field(gt=0, le=65535)
    context_length: int = Field(ge=8192)
    max_images: int = Field(gt=0)
    max_sequences: Literal[1]
    image_pixel_budget: int = Field(ge=65536, le=16777216)
    draft_tokens: int = Field(ge=1, le=8)


class ServerConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    port: int = Field(gt=0, le=65535)
    max_requests: Literal[1]
    timeout_seconds: int = Field(gt=0)
    idle_timeout_seconds: int = Field(gt=0)
    engine: EngineConfig

    @model_validator(mode="after")
    def ports_differ(self):
        if self.port == self.engine.port:
            raise ValueError("Public and engine ports must differ")
        return self


def load_config(path: Path) -> ServerConfig:
    return ServerConfig.model_validate(tomllib.loads(path.read_text()))
