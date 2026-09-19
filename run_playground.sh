#!/usr/bin/env bash
set -euo pipefail
if (( $# != 0 )); then
  echo 'Usage: ./run_playground.sh' >&2
  exit 2
fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$project_dir/playground/data"
"$project_dir/build_docker.sh"
# Discover host addresses, excluding Docker bridges and virtual container interfaces.
receipt_host_ips=""
if command -v ip >/dev/null 2>&1; then
  receipt_host_ips="$(ip -o -4 addr show up scope global | awk '
    $2 !~ /^(lo|docker[0-9]*|br-.*|veth.*)$/ {split($4, address, "/"); print address[1]}
  ' | sort -u)" || receipt_host_ips=""
fi
# Read the published port from the same Compose file used to start the services.
# Python runs in the existing image; no host Python installation is required.
docker compose --file "$project_dir/docker/docker-compose.yaml" config --format json | \
  docker run --rm -i --env RECEIPT_HOST_IPS="$receipt_host_ips" \
    --entrypoint python3 receipt-master-backend-ocr:local -c '
import json
import os
import sys

config = json.load(sys.stdin)
ports = config["services"]["backend_api"]["ports"]
if len(ports) != 1 or ports[0]["host_ip"] != "0.0.0.0" or ports[0]["protocol"] != "tcp":
    raise SystemExit("backend_api must publish one TCP port on 0.0.0.0")
port, target = ports[0]["published"], ports[0]["target"]
print(f"\nAPI mapping: 0.0.0.0:{port} -> backend_api:{target}")
print("Access URLs (the model loads on the first task):")
print(f"  Local health: http://localhost:{port}/health")
addresses = os.environ["RECEIPT_HOST_IPS"].split()
for address in addresses:
    print(f"  Network health: http://{address}:{port}/health")
    print(f"  APK:            http://{address}:{port}/receipt_master.apk")
if not addresses:
    print(f"  Host IP could not be detected; use your host IP with port {port}.")
    print(f"  Local APK: http://localhost:{port}/receipt_master.apk")
print("Use the address on the same network as your device. Ctrl+C stops the services.\n")
'

# Foreground Compose streams service logs and stops containers on Ctrl+C.
exec docker compose --file "$project_dir/docker/docker-compose.yaml" up --no-build --remove-orphans
