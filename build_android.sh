#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if (( $# > 1 )) || [[ ${1:-} != "" && ${1:-} != --prepare-only ]]; then
  echo 'Usage: ./build_android.sh [--prepare-only]' >&2
  exit 2
fi
prepare_command=(python3)
if [[ ${1:-} != --prepare-only ]]; then
  command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
  docker info >/dev/null
  docker buildx version >/dev/null
  prepare_command=(docker run --rm -i --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$project_dir,target=$project_dir" \
    --entrypoint python3 python:3.12-slim)
fi
"${prepare_command[@]}" - "$project_dir" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
workspace = root / 'build/flutter'
workspace.mkdir(parents=True, exist_ok=True)
shared = root / 'src/shared'
for name in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.metadata']:
    shutil.copy2(shared / name, workspace / name)
# Direct links keep Dart edits and hot reload connected to canonical source files.
for name in ['lib', 'resources']:
    target = workspace / name
    if target.is_symlink():
        target.unlink()
    elif target.exists():
        raise RuntimeError(f'Refusing to replace unexpected directory: {target}')
    target.symlink_to(shared / name, target_is_directory=True)
for name in ['android', 'ios', 'linux']:
    target = workspace / name
    if target.is_symlink():
        target.unlink()
    elif target.exists():
        shutil.rmtree(target)
    shutil.copytree(root / 'src' / name, target, ignore=shutil.ignore_patterns(
        '.gradle', '.kotlin', '.cxx', 'build', 'local.properties', 'key.properties',
        '*.keystore', '*.jks', 'ephemeral', 'Generated.xcconfig',
        'flutter_export_environment.sh', 'GeneratedPluginRegistrant.*', 'Pods', '.symlinks'))
print(f'Flutter workspace: {workspace}')
PY

if [[ ${1:-} == --prepare-only ]]; then
  exit 0
fi
# Serialize version allocation and publication across concurrent builds.
mkdir -p "$project_dir/build"
exec 9>"$project_dir/build/android-release.lock"
flock 9
signing_dir="$project_dir/build/android-signing"
mkdir -p "$signing_dir" "$project_dir/build/mobile"
chmod 700 "$signing_dir"
# Reuse the previous local development identity for upgrade compatibility.
if [[ ! -f "$signing_dir/debug.keystore" && -f "$HOME/.android/debug.keystore" ]]; then
  cp "$HOME/.android/debug.keystore" "$signing_dir/debug.keystore"
fi
if [[ ! -f "$signing_dir/debug.keystore" ]]; then
  docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$signing_dir,target=/signing" \
    eclipse-temurin:21-jdk-jammy keytool -genkeypair \
    -keystore /signing/debug.keystore -storepass android -alias androiddebugkey \
    -keypass android -dname 'CN=Android Debug,O=Android,C=US' \
    -keyalg RSA -keysize 2048 -validity 10000
fi
chmod 600 "$signing_dir/debug.keystore"
# Include the signing identity in cache invalidation without exposing the key.
signing_hash="$(docker run --rm --platform linux/amd64 \
  --mount "type=bind,source=$signing_dir,target=/signing,readonly" \
  eclipse-temurin:21-jdk-jammy sha256sum /signing/debug.keystore)"
bootstrap_file="${RECEIPT_BOOTSTRAP_FILE:-$project_dir/build/mobile-config/backend_defaults.json}"
if [[ ! -f "$bootstrap_file" ]]; then
  echo 'Missing backend defaults. Run ./build_docker.sh first or set RECEIPT_BOOTSTRAP_FILE.' >&2
  exit 1
fi
bootstrap_file="$(realpath "$bootstrap_file")"
docker run --rm --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$project_dir,target=/workspace,readonly" \
  --mount "type=bind,source=$bootstrap_file,target=/defaults.json,readonly" \
  python:3.12-slim python /workspace/docker/validate_mobile_defaults.py /defaults.json
bootstrap_hash="$(docker run --rm --mount "type=bind,source=$bootstrap_file,target=/defaults.json,readonly" \
  python:3.12-slim sha256sum /defaults.json)"
release_tool=(docker run --rm --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$project_dir,target=$project_dir" \
  --mount "type=bind,source=$bootstrap_file,target=/bootstrap.json,readonly" \
  python:3.12-slim python "$project_dir/docker/android_release.py")
build_number="$("${release_tool[@]}" choose --root "$project_dir" --bootstrap /bootstrap.json --signer "$signing_dir/debug.keystore")"
for attempt in 1 2; do
  docker buildx build --platform linux/amd64 --target artifacts \
    --secret "id=android_debug_key,src=$signing_dir/debug.keystore" \
    --secret "id=mobile_defaults,src=$bootstrap_file" \
    --build-arg "MOBILE_CONFIG_FINGERPRINT=${bootstrap_hash%% *}" \
    --build-arg "SIGNING_FINGERPRINT=${signing_hash%% *}" \
    --build-arg "ANDROID_BUILD_NUMBER=$build_number" \
    --output "type=local,dest=$project_dir/build/android-staging" \
    --file "$project_dir/docker/android.Dockerfile" "$project_dir"
  result="$("${release_tool[@]}" publish --root "$project_dir")"
  if [[ "$result" == published ]]; then
    echo "Android build $build_number published: $project_dir/build/mobile"
    exit 0
  fi
  build_number="$result"
done
echo 'APK changed unexpectedly during publication; no new release was published.' >&2
exit 1
