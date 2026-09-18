# Offline candidate benchmark only; not a playground service.
FROM ubuntu:24.04@sha256:b3cc40b72b93588182b5410f723c7aaf142363311c2aa993d8a453ddcbb3ae15
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 libstdc++6 ca-certificates libcurl4t64 && rm -rf /var/lib/apt/lists/*
COPY build/qwen38/runtime/llama-b11037/ /opt/llama/
COPY build/qwen38/runtime/cudart-llama-b11037-bin-ubuntu-cuda-12.8-x64/ /opt/llama/
ENV LD_LIBRARY_PATH=/opt/llama
ENTRYPOINT ["/opt/llama/llama-server"]
