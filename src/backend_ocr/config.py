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
    receipt_output_tokens: int = Field(gt=0)
    logo_output_tokens: int = Field(gt=0)
    thinking: bool
    temperature: float = Field(ge=0, le=2)
    seed: int = Field(ge=0)
    max_sequences: Literal[1]
    image_pixel_budget: int = Field(ge=65536, le=16777216)
    draft_tokens: int = Field(ge=1, le=8)


class GeneralConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    host: str
    port: int = Field(gt=0, le=65535)
    api_key: str = Field(min_length=24)
    max_requests: Literal[1]
    timeout_seconds: int = Field(gt=0)
    idle_timeout_seconds: int = Field(gt=0)

    @model_validator(mode="after")
    def valid_host(self):
        import ipaddress

        ipaddress.ip_address(self.host)
        return self


class ServerConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    general: GeneralConfig
    engine: EngineConfig

    @model_validator(mode="after")
    def ports_differ(self):
        if self.general.port == self.engine.port:
            raise ValueError("Public and engine ports must differ")
        return self


def load_config(data_dir: Path) -> ServerConfig:
    if not data_dir.is_absolute() or not data_dir.is_dir():
        raise ValueError("Data directory must be an existing absolute directory")
    return ServerConfig.model_validate(tomllib.loads((data_dir / "config.toml").read_text()))
