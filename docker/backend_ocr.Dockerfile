# syntax=docker/dockerfile:1
FROM python:3.12-slim AS checks
WORKDIR /workspace
RUN pip install --no-cache-dir fastapi==0.136.3 httpx==0.28.1 pillow==11.3.0 numpy==2.2.6 opencv-python-headless==4.13.0.92
COPY src/backend_ocr/ src/backend_ocr/
COPY tests/backend_ocr/ tests/backend_ocr/
RUN python -m unittest discover -s tests/backend_ocr && touch /checks-passed

FROM python:3.12-slim AS weights
RUN pip install --no-cache-dir huggingface-hub==0.34.4
ENV HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_DISABLE_XET=1
COPY docker/download_model.py /download_model.py
RUN python /download_model.py --name unlimited-ocr --repository baidu/Unlimited-OCR --revision 07dea832e22aefee32ad281d4b80551282e1c168
COPY docker/download_logo_models.py /download_logo_models.py
RUN python /download_logo_models.py

RUN python /download_model.py --name ppocr-det --repository PaddlePaddle/PP-OCRv6_medium_det --revision 8e0f56fb2ef86b461d99cfc7ac5c137738985f61
RUN python /download_model.py --name ppocr-rec --repository PaddlePaddle/PP-OCRv6_medium_rec --revision e5a92bcbc5cc1b494628e458d267778f0704fd7c

FROM vllm/vllm-openai:unlimited-ocr@sha256:542961a42d9183813819a23ef3a8b50bfb4f5ef7b0fb4f8e4f56edd8445efb18 AS runtime
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/paddle && /opt/paddle/bin/pip install --no-cache-dir paddleocr==3.7.0 paddlepaddle==3.3.0 fastapi==0.136.3 uvicorn==0.35.0
ENV PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
RUN pip install --no-cache-dir kornia==0.8.2 opencv-python-headless==4.13.0.92 \
    && pip install --no-cache-dir --no-deps https://github.com/cvg/LightGlue/archive/eb42fee2d71449efb0aa5c10549752b5d75384d8.zip
WORKDIR /app
COPY --from=checks /checks-passed /app/checks-passed
COPY --from=weights /models/unlimited-ocr /models/unlimited-ocr
COPY --from=weights /models/ppocr-det /models/ppocr-det
COPY --from=weights /models/ppocr-rec /models/ppocr-rec
COPY --from=weights /models/logo-matching /models/logo-matching
COPY src/backend_ocr/ /app/
COPY src/backend_api/resources/merchants/ /logo-tests/samples/
COPY tests/backend_ocr/logo_evaluation.py /logo-tests/tests/backend_ocr/logo_evaluation.py
RUN --network=none PYTHONPATH=/app python3 /logo-tests/tests/backend_ocr/logo_evaluation.py --samples /logo-tests/samples --weights /models/logo-matching > /app/logo-regression.json
ENTRYPOINT ["python3", "/app/main.py"]
CMD ["--config", "/config/backend_ocr.toml"]
