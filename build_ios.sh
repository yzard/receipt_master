#!/usr/bin/env bash
set -euo pipefail
if (( $# != 1 )); then
  echo 'Usage: ./build_ios.sh /absolute/path/to/flutter (requires macOS/Xcode)' >&2
  exit 2
fi
if [[ $(uname -s) != Darwin ]]; then
  echo 'iOS compilation requires macOS and Xcode.' >&2
  exit 1
fi
flutter_bin="$1"
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_file="${RECEIPT_BOOTSTRAP_FILE:-$project_dir/build/mobile-config/backend_defaults.json}"
if [[ ! -f "$bootstrap_file" ]]; then
  echo 'Missing backend defaults. Set RECEIPT_BOOTSTRAP_FILE to a configured backend_defaults.json.' >&2
  exit 1
fi
python3 "$project_dir/docker/validate_mobile_defaults.py" "$bootstrap_file"
"$project_dir/build_android.sh" --prepare-only
cd "$project_dir/src/shared"
"$flutter_bin" pub get --enforce-lockfile
"$(dirname -- "$flutter_bin")/dart" format --output=none --set-exit-if-changed lib "$project_dir/tests/shared"
"$flutter_bin" analyze
cd "$project_dir/tests/shared"
"$flutter_bin" pub get --enforce-lockfile
"$flutter_bin" analyze
"$flutter_bin" test domain database ui
cd "$project_dir/build/flutter"
"$flutter_bin" pub get --enforce-lockfile
python3 "$project_dir/docker/prepare_ios_defaults.py" "$project_dir/build/flutter" "$bootstrap_file"
"$flutter_bin" build ios --debug --no-codesign
