#!/usr/bin/env bash
set -euo pipefail
if (( $# != 0 )); then echo 'Usage: ./build_web.sh' >&2; exit 2; fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
docker buildx build --target artifacts --file "$project_dir/docker/web.Dockerfile" \
  --output "type=local,dest=$project_dir/build/web" "$project_dir"
echo "Web build: $project_dir/build/web"
