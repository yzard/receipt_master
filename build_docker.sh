#!/usr/bin/env bash
set -euo pipefail
if (( $# != 0 )); then
  echo 'Usage: ./build_docker.sh' >&2
  exit 2
fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PUID="${PUID:-$(id -u)}" GUID="${GUID:-$(id -g)}"
python3 -m unittest discover -s "$project_dir/tests" -p test_playground_config.py
if [[ -d "$project_dir/playground/data" || -d "$project_dir/playground/backend_api/data" || -d "$project_dir/playground/backend_ocr/data" ]]; then
  # Old containers can own SQLite WAL and root-owned directories; stop them before moving data.
  docker compose --file "$project_dir/docker/docker-compose.yaml" stop
  docker run --rm --mount "type=bind,source=$project_dir,target=/workspace" \
    python:3.12-slim python /workspace/docker/prepare_playground_config.py \
    --root /workspace --migrate-only
fi
python3 "$project_dir/docker/prepare_playground_config.py" --root "$project_dir"
# Each backend image includes its own mandatory checks; neither build needs a GPU.
for component in backend_ocr backend_api; do
  docker buildx build --platform linux/amd64 --target checks \
    --file "$project_dir/docker/$component.Dockerfile" "$project_dir"
done
# Provision before Android compilation so the APK and server share one persistent key.
receipt_host=""
if command -v ip >/dev/null 2>&1; then
  receipt_host="$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
if [[ -z "$receipt_host" && -z "${RECEIPT_BACKEND_ENDPOINT:-}" ]]; then
  echo 'Set RECEIPT_BACKEND_ENDPOINT to a phone-accessible backend URL.' >&2
  exit 1
fi
docker compose --file "$project_dir/docker/docker-compose.yaml" config --format json | \
  docker run --rm -i --user "$(id -u):$(id -g)" \
    --env RECEIPT_BACKEND_ENDPOINT="${RECEIPT_BACKEND_ENDPOINT:-}" \
    --mount "type=bind,source=$project_dir,target=/workspace" \
    python:3.12-slim python /workspace/docker/prepare_mobile_defaults.py --root /workspace --host "$receipt_host"
RECEIPT_BOOTSTRAP_FILE="$project_dir/build/mobile-config/backend_defaults.json" "$project_dir/build_android.sh"
docker buildx build --platform linux/amd64 --load --tag receipt-master-backend-ocr:local \
  --file "$project_dir/docker/backend_ocr.Dockerfile" "$project_dir"
docker buildx build --platform linux/amd64 --load --tag receipt-master-backend-api:local \
  --file "$project_dir/docker/backend_api.Dockerfile" "$project_dir"
