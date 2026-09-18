"""Isolated Paddle runtime: text and geometric evidence only, no receipt rules."""
import argparse
import asyncio
import base64
from contextlib import asynccontextmanager
from io import BytesIO

from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel


class Request(BaseModel):
    image: str


def create_application(args):
    @asynccontextmanager
    async def lifespan(app):
        from paddleocr import PaddleOCR
        app.state.ocr = PaddleOCR(
            text_detection_model_name="PP-OCRv6_medium_det",
            text_detection_model_dir=args.detection_path,
            text_recognition_model_name="PP-OCRv6_medium_rec",
            text_recognition_model_dir=args.recognition_path,
            use_doc_orientation_classify=False, use_doc_unwarping=False,
            use_textline_orientation=False, device="cpu", cpu_threads=args.threads,
            enable_mkldnn=False,
        )
        app.state.lock = asyncio.Lock()
        yield

    app = FastAPI(lifespan=lifespan)

    @app.get("/health")
    async def health():
        return {"status": "ready"}

    def recognize(image):
        import numpy as np
        data = np.array(Image.open(BytesIO(base64.b64decode(image.split(",", 1)[1], validate=True))).convert("RGB"))[:, :, ::-1]
        height, width = data.shape[:2]
        results = list(app.state.ocr.predict(data))
        if len(results) != 1:
            raise ValueError("Expected one OCR page")
        result = results[0].json
        raw = result.get("res", result)
        words = []
        for text, confidence, polygon in zip(raw["rec_texts"], raw["rec_scores"], raw["rec_polys"], strict=True):
            xs, ys = zip(*polygon)
            words.append({"text": text, "confidence": float(confidence), "box": [
                max(0, min(xs) / width), max(0, min(ys) / height),
                min(1, max(xs) / width), min(1, max(ys) / height),
            ]})
        return {"words": words}

    @app.post("/recognize")
    async def run(body: Request):
        async with app.state.lock:
            return await asyncio.to_thread(recognize, body.image)

    return app


if __name__ == "__main__":
    import uvicorn
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--detection-path", required=True)
    parser.add_argument("--recognition-path", required=True)
    parser.add_argument("--threads", type=int, required=True)
    args = parser.parse_args()
    uvicorn.run(create_application(args), host="127.0.0.1", port=args.port)
