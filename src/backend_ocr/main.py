"""Two text OCR engines and local logo matching inside one internal container."""

import argparse
import asyncio
import base64
import binascii
import logging
import os
import signal
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
    os.killpg(process.pid, signal.SIGTERM)
    try:
        await asyncio.wait_for(process.wait(), 20)
    except TimeoutError:
        os.killpg(process.pid, signal.SIGKILL)
        await process.wait()


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
                image.save(data, format="JPEG", quality=95)
            except (ValueError, binascii.Error, OSError, UnidentifiedImageError, Image.DecompressionBombError):
                raise HTTPException(400, "Invalid image") from None
            part["image_url"]["url"] = "data:image/jpeg;base64," + base64.b64encode(data.getvalue()).decode()
            images += 1
    if not 1 <= images <= config.engine.max_images:
        raise HTTPException(400, "Image count outside configured model capacity")
    # Allocate the visual context across every photo; never silently discard a page.
    return body


def create_application(config: ServerConfig):
    @asynccontextmanager
    async def lifespan(app):
        engine = await asyncio.create_subprocess_exec(*command_for(config.engine), start_new_session=True)
        paddle = await asyncio.create_subprocess_exec(
            config.paddle.python,
            str(Path(__file__).with_name("paddle_worker.py")),
            "--port",
            str(config.paddle.port),
            "--detection-path",
            config.paddle.detection_path,
            "--recognition-path",
            config.paddle.recognition_path,
            "--threads",
            str(config.paddle.threads),
            start_new_session=True,
        )
        monitor = None
        try:
            async with httpx.AsyncClient(timeout=config.timeout_seconds, trust_env=False) as client:
                app.state.client = client
                app.state.engine = engine
                app.state.paddle = paddle
                app.state.paddle_ready = False
                app.state.requests = asyncio.Semaphore(config.max_requests)
                from logo_matching import LogoMatcher

                app.state.logo_matcher = await asyncio.to_thread(LogoMatcher, config.logo_model_path, 128)
                app.state.logo_lock = asyncio.Lock()

                async def watch():
                    waits = [asyncio.create_task(p.wait()) for p in (engine, paddle)]
                    try:
                        await asyncio.wait(waits, return_when=asyncio.FIRST_COMPLETED)
                    finally:
                        for wait in waits:
                            wait.cancel()
                        await asyncio.gather(*waits, return_exceptions=True)
                    os.kill(os.getpid(), signal.SIGTERM)

                monitor = asyncio.create_task(watch())
                yield
        finally:
            if monitor is not None:
                monitor.cancel()
                await asyncio.gather(monitor, return_exceptions=True)
            await asyncio.gather(stop_process(engine), stop_process(paddle))

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
        if app.state.engine.returncode is not None or app.state.paddle.returncode is not None:
            raise HTTPException(503, "Vision worker unavailable")
        reply = await app.state.client.get(f"http://127.0.0.1:{config.engine.port}/health", timeout=2)
        if reply.status_code != 200:
            raise HTTPException(503, "Vision model loading")
        # CPU inference can temporarily hold Paddle's GIL. After startup has been
        # verified, process supervision determines liveness; queued work is not downtime.
        if not app.state.paddle_ready:
            pp = await app.state.client.get(f"http://127.0.0.1:{config.paddle.port}/health", timeout=2)
            if pp.status_code != 200:
                raise HTTPException(503, "PP-OCR model loading")
            app.state.paddle_ready = True
        return {"status": "ready", "models": [config.engine.model, "pp-ocrv6-medium"]}

    @app.post("/v1/logo/match")
    async def logo_match(body: dict):
        encoded = body.get("image")
        references = body.get("references")
        if not isinstance(encoded, str) or len(encoded) > 8 * 1024 * 1024:
            raise HTTPException(400, "Invalid logo image")
        if not isinstance(references, list) or not 1 <= len(references) <= 8:
            raise HTTPException(400, "Invalid logo references")
        ids = set()
        for reference in references:
            if (
                not isinstance(reference, dict)
                or not isinstance(reference.get("id"), str)
                or not reference["id"]
                or reference["id"] in ids
                or not isinstance(reference.get("image"), str)
                or len(reference["image"]) > 8 * 1024 * 1024
            ):
                raise HTTPException(400, "Invalid logo reference")
            ids.add(reference["id"])
        async with app.state.requests, app.state.logo_lock:
            try:
                return await asyncio.to_thread(app.state.logo_matcher.match, encoded, references)
            except (ValueError, OSError):
                raise HTTPException(400, "Invalid logo image") from None

    @app.post("/v1/ocr/recognize")
    async def completions(body: dict):
        request = await asyncio.to_thread(prepare_request, body, config)
        photos = [
            part["image_url"]["url"]
            for message in request["messages"]
            if isinstance(message.get("content"), list)
            for part in message["content"]
            if part["type"] == "image_url"
        ]
        pages = []
        usages = []
        async with app.state.requests:
            for photo in photos:
                unlimited_request = {
                    "model": config.engine.model,
                    "messages": [
                        {
                            "role": "user",
                            "content": [
                                {"type": "text", "text": "<image>document parsing."},
                                {"type": "image_url", "image_url": {"url": photo}},
                            ],
                        }
                    ],
                    "temperature": 0,
                    "max_tokens": min(int(body.get("max_tokens", 8192)), config.engine.context_length),
                    "skip_special_tokens": False,
                    "vllm_xargs": {"ngram_size": 35, "window_size": 128},
                }
                unlimited = await app.state.client.post(
                    f"http://127.0.0.1:{config.engine.port}/v1/chat/completions", json=unlimited_request
                )
                unlimited.raise_for_status()
                result = unlimited.json()
                choice = result.get("choices", [{}])[0]
                if choice.get("finish_reason") != "stop" or not isinstance(
                    choice.get("message", {}).get("content"), str
                ):
                    logging.getLogger(__name__).warning(
                        "Unlimited-OCR output rejected finish_reason=%s", choice.get("finish_reason")
                    )
                    raise HTTPException(502, "Unlimited-OCR output incomplete")
                paddle = await app.state.client.post(
                    f"http://127.0.0.1:{config.paddle.port}/recognize", json={"image": photo}
                )
                paddle.raise_for_status()
                pages.append({"unlimited": choice["message"]["content"], "paddle": paddle.json()})
                usages.append(result.get("usage"))
        usage = (
            {key: sum(u[key] for u in usages) for key in ("prompt_tokens", "completion_tokens", "total_tokens")}
            if all(
                isinstance(u, dict)
                and all(isinstance(u.get(k), int) for k in ("prompt_tokens", "completion_tokens", "total_tokens"))
                for u in usages
            )
            else None
        )
        return {"model": config.engine.model, "pages": pages, "usage": usage}

    return app


def main():
    import uvicorn

    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    config = load_config(parser.parse_args().config)
    uvicorn.run(create_application(config), host="0.0.0.0", port=config.port, log_level="info")


if __name__ == "__main__":
    main()
