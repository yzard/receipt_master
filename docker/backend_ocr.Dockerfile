# syntax=docker/dockerfile:1

FROM nvidia/cuda:13.1.2-devel-ubuntu24.04@sha256:b9f64abf7226fdb3463ca202bc99878ec847171e6c5f77bd34c8d1403fbf1eca AS build

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        cmake \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        libcurl4-openssl-dev \
        libswscale-dev \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:cf7bf3e151e87fd231ff26ee1f6c64dbe7521d9235105050ecb658d71e10ba22 https://codeload.github.com/Neroued/ninfer/tar.gz/9e163eee4b8acec21ab0ac765107b6a3f287b217 /tmp/ninfer.tar.gz
WORKDIR /src
RUN tar -xzf /tmp/ninfer.tar.gz --strip-components=1 -C /src && rm /tmp/ninfer.tar.gz

RUN cmake -S . -B /build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DNINFER_BUILD_APPS=ON \
        -DBUILD_TESTING=OFF \
        -DNINFER_BUILD_BENCHMARKS=OFF \
    && cmake --build /build --parallel 8 --target ninfer ninfer-serve

FROM python:3.12-slim AS checks
WORKDIR /workspace
RUN pip install --no-cache-dir fastapi==0.136.3 httpx==0.28.1 pillow==11.3.0
COPY src/backend_ocr/ src/backend_ocr/
COPY tests/backend_ocr/ tests/backend_ocr/
COPY docker/defaults/backend_ocr.toml docker/defaults/backend_ocr.toml
RUN python -m unittest discover -s tests/backend_ocr && touch /checks-passed

FROM nvidia/cuda:13.1.2-runtime-ubuntu24.04@sha256:bff001d3257971cc4752e15ac2d354befa70995ded8e141741ade50569fc192e

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        python3 python3-venv \
        gosu \
        ca-certificates \
        libavcodec60 \
        libavformat60 \
        libavutil58 \
        libcurl4t64 \
        libswscale7 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/apps/ninfer /usr/local/bin/ninfer
COPY --from=build /build/apps/ninfer-serve /usr/local/bin/ninfer-serve

ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 PYTHONUNBUFFERED=1
RUN python3 -m venv /opt/app
ENV PATH=/opt/app/bin:$PATH
RUN pip install --no-cache-dir fastapi==0.136.3 uvicorn==0.35.0 httpx==0.28.1 pillow==11.3.0
WORKDIR /app
COPY --from=checks /checks-passed /app/checks-passed
COPY src/backend_ocr/ /app/
ADD --chmod=644 --checksum=sha256:74d2c57145e6ff11d1d2faa79594477f9bc903a611af1fb20218189fbbb77d82 https://huggingface.co/neroued/Qwen3.8-27B-nvfp4-NInfer/resolve/f0b43ad436b9fa8142c6ed6647c470a6fe409484/qwen3_8_27b_nvfp4.ninfer /models/qwen3_8_27b_nvfp4.ninfer
RUN chmod 755 /models
COPY docker/service-entrypoint.sh /app/service-entrypoint.sh
RUN chmod +x /app/service-entrypoint.sh
ENV RECEIPT_SERVICE=ocr
ENTRYPOINT ["/app/service-entrypoint.sh", "python3", "/app/main.py"]
CMD ["--data-dir", "/data"]
