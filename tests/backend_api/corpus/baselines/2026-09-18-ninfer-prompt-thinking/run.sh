#!/usr/bin/env bash
set -euo pipefail
cd /home/zyin/dev/receipt_master
restore() {
  docker compose -f docker/ninfer_evaluation.compose.yaml logs --no-color > build/ninfer-prompt-thinking/inference.log || true
  docker compose -f docker/ninfer_evaluation.compose.yaml down
  docker compose -f docker/docker-compose.yaml start backend_ocr
}
trap restore EXIT
trap 'exit 130' INT TERM
docker compose -f docker/docker-compose.yaml stop backend_ocr
docker compose -f docker/ninfer_evaluation.compose.yaml up --no-build -d
ready=false
for ((i=0;i<180;i++)); do
  if curl -fsS http://127.0.0.1:5002/health > build/ninfer-prompt-thinking/health.json; then ready=true; break; fi
  sleep 2
done
if [[ "$ready" != true ]]; then docker compose -f docker/ninfer_evaluation.compose.yaml logs; exit 1; fi
python3 tests/backend_api/qwen38_evaluation.py \
  --snapshot tests/backend_api/corpus/baselines/2026-09-18-qwen38-q4/snapshot.json \
  --output build/ninfer-prompt-thinking/thinking \
  --url http://127.0.0.1:5002 \
  --model qwen3.8-27b-ninfer-nvfp4 \
  --output-mode prompt \
  --thinking on
