#!/usr/bin/env bash
set -euo pipefail
if (( $# < 1 || $# > 2 )) || [[ ${2:-} != "" && ${2:-} != --simulator ]]; then
  echo 'Usage: ./build_ios.sh /absolute/path/to/flutter [--simulator] (requires macOS/Xcode)' >&2
  exit 2
fi
if [[ $(uname -s) != Darwin ]]; then
  echo 'iOS compilation requires macOS and Xcode.' >&2
  exit 1
fi
flutter_bin="$1"
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$project_dir/docker/build_lifecycle.sh"
receipt_build_start ios
export PUB_CACHE="$RECEIPT_BUILD_WORK/pub-cache"
export CP_HOME_DIR="$RECEIPT_BUILD_WORK/cocoapods" CP_CACHE_DIR="$RECEIPT_BUILD_WORK/cocoapods/cache"
bootstrap_file="${RECEIPT_BOOTSTRAP_FILE:-$project_dir/build/mobile-config/backend_defaults.json}"
if [[ ! -f "$bootstrap_file" ]]; then
  echo 'Missing backend defaults. Set RECEIPT_BOOTSTRAP_FILE to a configured backend_defaults.json.' >&2
  exit 1
fi
python3 "$project_dir/docker/validate_mobile_defaults.py" "$bootstrap_file"
receipt_target_inputs "ios${2:-}" build_ios.sh build_android.sh docker/prepare_ios_defaults.py docker/validate_mobile_defaults.py src/shared src/ios tests/shared
flutter_version="$("$flutter_bin" --version --machine)"
xcode_version="$(xcodebuild -version)"
receipt_key="$("${receipt_state[@]}" fingerprint "${receipt_inputs[@]}" --value "$(cat "$bootstrap_file")" --value "$flutter_version" --value "$xcode_version")"
if [[ ${2:-} == --simulator ]]; then
  app_target="$project_dir/build/mobile/receipt-master-ios-simulator.zip"
else
  app_target="$project_dir/build/mobile/receipt-master-ios-unsigned.zip"
fi
receipt_target_probe "${app_target#"$project_dir/"}"
if [[ "$receipt_reuse" == reusable ]]; then
  echo 'iOS inputs and final outputs are unchanged; reusing the application archive.'
  exit 0
fi
"$project_dir/build_android.sh" --prepare-only
cd "$project_dir/src/shared"
"$flutter_bin" pub get --enforce-lockfile
"$(dirname -- "$flutter_bin")/dart" format --output=none --set-exit-if-changed lib "$project_dir/tests/shared"
"$flutter_bin" analyze
cd "$project_dir/tests/shared"
"$flutter_bin" pub get --enforce-lockfile
"$flutter_bin" analyze
"$flutter_bin" test --dart-define=TEST_PLATFORM=ios domain database ui
cd "$project_dir/build/flutter"
"$flutter_bin" pub get --enforce-lockfile
python3 "$project_dir/docker/prepare_ios_defaults.py" "$project_dir/build/flutter" "$bootstrap_file"
if [[ ${2:-} == --simulator ]]; then
  "$flutter_bin" build ios --simulator --debug
else
  "$flutter_bin" build ios --release --no-codesign
fi

if [[ ${2:-} == --simulator ]]; then
  app_source="$project_dir/build/flutter/build/ios/iphonesimulator/Runner.app"
  app_target="$project_dir/build/mobile/receipt-master-ios-simulator.zip"
else
  app_source="$project_dir/build/flutter/build/ios/iphoneos/Runner.app"
  app_target="$project_dir/build/mobile/receipt-master-ios-unsigned.zip"
fi
python3 "$project_dir/docker/build_cleanup.py" export-ios --source "$app_source" --target "$app_target"
receipt_target_record
echo "iOS application: $app_target"
