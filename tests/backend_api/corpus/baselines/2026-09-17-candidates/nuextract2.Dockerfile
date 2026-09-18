# syntax=docker/dockerfile:1
FROM python:3.12-slim AS checks
WORKDIR /workspace
RUN pip install --no-cache-dir fastapi==0.136.3 httpx==0.28.1 pillow==11.3.0
COPY src/backend_ocr/ src/backend_ocr/
COPY tests/backend_ocr/ tests/backend_ocr/
RUN python -m unittest discover -s tests/backend_ocr && touch /checks-passed

FROM python:3.12-slim AS weights
RUN pip install --no-cache-dir huggingface-hub==0.34.4
ENV HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_DISABLE_XET=1
COPY docker/download_model.py /download_model.py
RUN python /download_model.py --name receipt-vision --repository numind/NuExtract-2.0-8B --revision a470f0b5dd0b42fa7182cdbe7c6113a232f671e4
RUN python /download_model.py --name logo-embedding --repository facebook/dinov2-small --revision ed25f3a31f01632728cabb09d1542f84ab7b0056

FROM vllm/vllm-openai:unlimited-ocr@sha256:542961a42d9183813819a23ef3a8b50bfb4f5ef7b0fb4f8e4f56edd8445efb18 AS runtime
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --from=checks /checks-passed /app/checks-passed
COPY --from=weights /models/receipt-vision /models/receipt-vision
COPY --from=weights /models/logo-embedding /models/logo-embedding
COPY src/backend_ocr/ /app/
ENTRYPOINT ["python3", "/app/main.py"]
CMD ["--config", "/config/backend_ocr.toml"]
