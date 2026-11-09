#!/usr/bin/env bash
set -euo pipefail

project_dir="$1"
build_work="$2"
image_id="$3"
if [[ ! "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo 'Pass the full ID of the final API image to the security scan.' >&2
  exit 2
fi

osv_image='ghcr.io/google/osv-scanner:v2.7.1@sha256:a70ffffc2bfd33482953e5d6b64c6fcdb30239717a07b0f0d3ab2859ce3e4cde'
trivy_image='docker.io/aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb'
scanner_user="$(id -u):$(id -g)"

echo 'Scanning the Rust, Web and Flutter lockfiles with OSV-Scanner.'
docker run --rm --user "$scanner_user" \
  --mount "type=bind,source=$project_dir/src/backend_api/Cargo.lock,target=/inputs/Cargo.lock,readonly" \
  --mount "type=bind,source=$project_dir/src/web/package-lock.json,target=/inputs/package-lock.json,readonly" \
  --mount "type=bind,source=$project_dir/src/shared/pubspec.lock,target=/inputs/pubspec.lock,readonly" \
  "$osv_image" scan source --all-vulns \
  --lockfile /inputs/Cargo.lock --lockfile /inputs/package-lock.json --lockfile /inputs/pubspec.lock

umask 077
scan_dir="$(mktemp -d "$build_work/security.XXXXXX")"
docker image save "$image_id" > "$scan_dir/api.tar"
echo "Scanning final API image $image_id with Trivy."
if ! docker run --rm --user "$scanner_user" \
  --mount "type=bind,source=$scan_dir,target=/scan" \
  "$trivy_image" image --input /scan/api.tar --cache-dir /scan/cache \
  --scanners vuln,secret --exit-code 1 --format json --output /scan/image.json; then
  echo "Image security scan failed. Private report path: $scan_dir/image.json" >&2
  if [[ -s "$scan_dir/image.json" ]]; then
    python3 - "$scan_dir/image.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as report:
    for result in json.load(report).get('Results') or []:
        for finding in result.get('Vulnerabilities') or []:
            print(f"{finding['VulnerabilityID']}: {finding['PkgName']} {finding['InstalledVersion']}", file=sys.stderr)
        for finding in result.get('Secrets') or []:
            print(f"Secret finding: {finding['RuleID']}", file=sys.stderr)
PY
  fi
  exit 1
fi
echo 'Release security scans passed.'
