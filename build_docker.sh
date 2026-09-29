#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat <<'USAGE'
Usage: ./build_docker.sh [--publish dockerhub|github --username NAME]

No arguments: build and test locally without publishing.
--publish dockerhub  Push both backend images to docker.io/NAME/...
--publish github     Push both backend images to ghcr.io/NAME/...
--username NAME      Registry user or organization namespace (required for publishing).
--help               Show this help.

Image tags: YYYYMMDD (build start date in the host timezone) and latest.
Both tags point to the same image; publication pushes both tags for each backend.
Log in first with docker login docker.io or docker login ghcr.io.
Publishing starts only after Android, Web, backends and container HTTP checks pass.
USAGE
}
fail_usage() {
  echo "$1" >&2
  usage >&2
  exit 2
}
publish_registry=""
publish_namespace=""
while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --publish|--username)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail_usage "Missing value for $1."
      case "$1" in
        --publish) [[ -z "$publish_registry" ]] || fail_usage 'Specify --publish once.'; publish_registry="$2" ;;
        --username) [[ -z "$publish_namespace" ]] || fail_usage 'Specify --username once.'; publish_namespace="${2,,}" ;;
      esac
      shift 2
      ;;
    *) fail_usage "Unknown argument: $1" ;;
  esac
done
if [[ -n "$publish_registry" ]]; then
  case "$publish_registry" in
    dockerhub) publish_host="docker.io" ;;
    github) publish_host="ghcr.io" ;;
    *) fail_usage '--publish must be dockerhub or github.' ;;
  esac
  [[ "$publish_namespace" =~ ^[a-z0-9]+([_-][a-z0-9]+)*$ ]] || fail_usage 'Provide a valid --username namespace.'
elif [[ -n "$publish_namespace" ]]; then
  fail_usage '--username requires --publish.'
fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Read once so long builds crossing midnight still have one shared release date.
build_tag="$(date +%Y%m%d)"
[[ "$build_tag" =~ ^[0-9]{8}$ ]] || fail_usage 'Unable to determine YYYYMMDD build date.'
echo "Build date tag: $build_tag"
export PUID="${PUID:-$(id -u)}" PGID="${PGID:-$(id -g)}"
python3 -m unittest discover -s "$project_dir/tests/docker" -p 'test_*.py'
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
"$project_dir/build_web.sh"
for component in backend_ocr backend_api; do
  docker buildx build --platform linux/amd64 --target checks \
    --file "$project_dir/docker/$component.Dockerfile" "$project_dir"
done
# Provision the phone-accessible service origin before Android compilation.
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
# The API runtime image copies the published APK, manifest and immutable update
# packages from build/mobile; Android must finish before the runtime image build.
docker buildx build --platform linux/amd64 --load --tag "receipt-master-backend-ocr:$build_tag" \
  --file "$project_dir/docker/backend_ocr.Dockerfile" "$project_dir"
ocr_image_id="$(docker image inspect --format '{{.Id}}' "receipt-master-backend-ocr:$build_tag")"
docker buildx build --platform linux/amd64 --load --tag "receipt-master-backend-api:$build_tag" \
  --file "$project_dir/docker/backend_api.Dockerfile" "$project_dir"
api_image_id="$(docker image inspect --format '{{.Id}}' "receipt-master-backend-api:$build_tag")"

# Exercise the actual API/Web image with disposable accounts, never the playground volume.
python3 "$project_dir/tests/web/http_smoke.py" --image "$api_image_id" --artifacts "$project_dir/build/mobile"

# Only successful, verified builds advance latest. These are aliases, not new builds.
docker image tag "$ocr_image_id" receipt-master-backend-ocr:latest
docker image tag "$api_image_id" receipt-master-backend-api:latest
echo "Built both backend images as $build_tag with latest aliases."

if [[ -n "$publish_registry" ]]; then
  ocr_repo="$publish_host/$publish_namespace/receipt-master-backend-ocr"
  api_repo="$publish_host/$publish_namespace/receipt-master-backend-api"
  # Pin publication to the built/tested images, rather than mutable local tags.
  for image_tag in "$build_tag" latest; do
    docker image tag "$ocr_image_id" "$ocr_repo:$image_tag"
    docker image tag "$api_image_id" "$api_repo:$image_tag"
  done
  # Upload both dated images before advancing either registry latest alias.
  for image_tag in "$build_tag" latest; do
    for image_repo in "$ocr_repo" "$api_repo"; do
      echo "Publishing $image_repo:$image_tag"
      docker image push "$image_repo:$image_tag"
    done
  done
  echo "Published both backend images with tags $build_tag and latest."
fi
