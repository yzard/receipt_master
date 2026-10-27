#!/usr/bin/env bash
set -euo pipefail
if (( $# != 0 )); then echo 'Usage: ./build_web.sh' >&2; exit 2; fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$project_dir/docker/build_lifecycle.sh"
receipt_build_start web
receipt_target_inputs web build_web.sh docker/web.Dockerfile docker/web.Dockerfile.dockerignore src/web tests/web src/backend_api/resources/localizations.json
receipt_target_probe build/web
if [[ "$receipt_reuse" == reusable ]]; then
  echo 'Web inputs and final outputs are unchanged; reusing the Web application.'
  exit 0
fi
receipt_docker_build --target artifacts --file "$project_dir/docker/web.Dockerfile" \
  --output "type=local,dest=$RECEIPT_BUILD_WORK/web" "$project_dir"
python3 "$project_dir/docker/build_cleanup.py" export-web --source "$RECEIPT_BUILD_WORK/web" --target "$project_dir/build/web"
receipt_target_record
echo "Web build: $project_dir/build/web"
