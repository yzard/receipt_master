"""One queued NInfer vision engine for all receipt and logo inference."""

import argparse
import asyncio
import base64
import binascii
import logging
import os
import signal
import time
from contextlib import asynccontextmanager
from io import BytesIO
from pathlib import Path

import httpx
from config import ServerConfig, load_config
from fastapi import FastAPI, HTTPException
from PIL import Image, ImageOps, UnidentifiedImageError
from recipe import command_for


async def stop_process(process):
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        await process.wait()
        return
    try:
        await asyncio.wait_for(process.wait(), 20)
    except TimeoutError:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await process.wait()


class EngineRuntime:
    """Own the native process and serialize its lifetime with inference."""

    def __init__(self, config, client):
        self.config = config
        self.client = client
        self.process = None
        self.state = "unloaded"
        self.requests = asyncio.Semaphore(config.max_requests)
        self.pending = 0
        self.last_finished = time.monotonic()

    @asynccontextmanager
    async def slot(self):
        self.pending += 1
        try:
            async with self.requests:
                yield
        finally:
            self.pending -= 1
            self.last_finished = time.monotonic()

    async def stop(self):
        if self.process is not None:
            self.state = "stopping"
            await stop_process(self.process)
            self.process = None
            logging.getLogger(__name__).info("NInfer stopped; model memory released")
        self.state = "unloaded"

    async def ensure_ready(self):
        if self.process is not None and self.process.returncode is None:
            return
        await self.stop()
        self.state = "loading"
        logging.getLogger(__name__).info("Starting NInfer and loading model on demand")
        try:
            async with asyncio.timeout(self.config.timeout_seconds):
                self.process = await asyncio.create_subprocess_exec(
                    *command_for(self.config.engine), start_new_session=True
                )
                while self.process.returncode is None:
                    try:
                        reply = await self.client.get(f"http://127.0.0.1:{self.config.engine.port}/health", timeout=2)
                        if reply.status_code == 200:
                            self.state = "ready"
                            return
                    except httpx.TransportError:
                        pass
                    await asyncio.sleep(0.25)
                raise RuntimeError("NInfer exited during model loading")
        except asyncio.CancelledError:
            await self.stop()
            raise
        except (OSError, ValueError, RuntimeError, TimeoutError) as error:
            await self.stop()
            logging.getLogger(__name__).exception("NInfer model loading failed")
            raise HTTPException(503, "Vision model could not be loaded") from error

    async def idle_watch(self):
        while True:
            await asyncio.sleep(min(1, self.config.idle_timeout_seconds))
            async with self.requests:
                if self.pending == 0 and time.monotonic() - self.last_finished >= self.config.idle_timeout_seconds:
                    await self.stop()

    async def infer(self, request):
        try:
            # Bound cold loading and inference together, rather than granting two timeouts.
            async with asyncio.timeout(self.config.timeout_seconds):
                await self.ensure_ready()
                self.state = "busy"
                reply = await self.client.post(
                    f"http://127.0.0.1:{self.config.engine.port}/v1/chat/completions", json=request
                )
                reply.raise_for_status()
                return reply.json()
        except (asyncio.CancelledError, httpx.TransportError, TimeoutError) as error:
            # Disconnecting HTTP alone can leave native generation running. Reap it before
            # admitting another request, including after timeout or server cancellation.
            await self.stop()
            if isinstance(error, TimeoutError):
                raise HTTPException(504, "Vision inference timed out") from error
            raise
        finally:
            if self.process is not None:
                self.state = "ready" if self.process.returncode is None else "unloaded"


def prepare_request(body: dict, config: ServerConfig) -> dict:
    if body.get("model") != config.engine.model or body.get("stream", False):
        raise HTTPException(400, "Invalid model or streaming request")
    if not isinstance(body.get("messages"), list):
        raise HTTPException(400, "Invalid messages")
    photo_count = sum(
        1
        for message in body["messages"]
        if isinstance(message, dict) and isinstance(message.get("content"), list)
        for part in message["content"]
        if isinstance(part, dict) and part.get("type") == "image_url"
    )
    if not 1 <= photo_count <= config.engine.max_images:
        raise HTTPException(400, "Image count outside configured model capacity")
    images = 0
    for message in body.get("messages", []):
        if not isinstance(message, dict):
            raise HTTPException(400, "Invalid message")
        if not isinstance(message.get("content"), list):
            continue
        for part in message["content"]:
            if not isinstance(part, dict) or part.get("type") not in {"text", "image_url"}:
                raise HTTPException(400, "Only text and inline images are supported")
            if part["type"] != "image_url":
                continue
            if not isinstance(part.get("image_url"), dict):
                raise HTTPException(400, "Invalid image part")
            url = part["image_url"].get("url", "")
            if not isinstance(url, str) or not url.startswith(
                ("data:image/jpeg;base64,", "data:image/png;base64,", "data:image/webp;base64,")
            ):
                raise HTTPException(400, "Inline image required")
            try:
                image = Image.open(BytesIO(base64.b64decode(url.split(",", 1)[1], validate=True)))
                image = ImageOps.exif_transpose(image).convert("RGB")
                data = BytesIO()
                budget = config.engine.image_pixel_budget // photo_count
                scale = min(1.0, (budget / (image.width * image.height)) ** 0.5)
                if scale < 1:
                    image = image.resize(
                        (max(1, int(image.width * scale)), max(1, int(image.height * scale))), Image.Resampling.LANCZOS
                    )
                image.save(data, format="PNG")
            except (ValueError, binascii.Error, OSError, UnidentifiedImageError, Image.DecompressionBombError):
                raise HTTPException(400, "Invalid image") from None
            part["image_url"]["url"] = "data:image/png;base64," + base64.b64encode(data.getvalue()).decode()
            images += 1
    if not 1 <= images <= config.engine.max_images:
        raise HTTPException(400, "Image count outside configured model capacity")
    # Allocate the visual context across every photo; never silently discard a page.
    return body


def create_application(config: ServerConfig):
    @asynccontextmanager
    async def lifespan(app):
        async with httpx.AsyncClient(timeout=config.timeout_seconds, trust_env=False) as client:
            runtime = EngineRuntime(config, client)
            app.state.runtime = runtime
            monitor = asyncio.create_task(runtime.idle_watch())
            try:
                yield
            finally:
                monitor.cancel()
                await asyncio.gather(monitor, return_exceptions=True)
                await runtime.stop()

    app = FastAPI(lifespan=lifespan)

    @app.exception_handler(httpx.HTTPError)
    async def upstream_error(_request, error):
        from fastapi.responses import JSONResponse

        # Log transport metadata only: no photo payload, receipt text or auth headers.
        logging.getLogger(__name__).warning(
            "OCR upstream failure port=%s error=%s status=%s",
            error.request.url.port,
            type(error).__name__,
            error.response.status_code if isinstance(error, httpx.HTTPStatusError) else None,
        )
        return JSONResponse(status_code=502, content={"detail": "Vision inference unavailable"})

    @app.get("/health")
    async def health():
        runtime = app.state.runtime
        state = runtime.state
        if runtime.process is not None and runtime.process.returncode is not None:
            state = "unloaded"
        # Availability means jobs can be accepted, even with an unloaded model.
        # Health polling must neither load the model nor extend its idle deadline.
        return {"status": "ready", "models": [config.engine.model], "engine_state": state}

    @app.post("/v1/chat/completions")
    async def completions(body: dict):
        runtime = app.state.runtime
        # Admit before image decoding so queued requests cannot allocate many decoded photos.
        async with runtime.slot():
            request = await asyncio.to_thread(prepare_request, body, config)
            return await runtime.infer(request)

    return app


def main():
    import uvicorn

    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    config = load_config(parser.parse_args().config)
    uvicorn.run(create_application(config), host="0.0.0.0", port=config.port, log_level="info")


if __name__ == "__main__":
    main()
