# Source after argument validation. Child entrypoints share their parent's session.
receipt_build_start() {
  receipt_component="$1"
  receipt_owner=0
  if [[ -z "${RECEIPT_BUILD_WORK:-}" ]]; then
    mkdir -p "$project_dir/build"
    exec 9>"$project_dir/build/.build.lock"
    python3 - <<'PY'
import fcntl
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Another Receipt Master build owns the output directory.')
PY
    RECEIPT_BUILD_WORK="$(mktemp -d "$project_dir/build/work.XXXXXX")"
    RECEIPT_BUILD_BUILDER=""
    export RECEIPT_BUILD_WORK RECEIPT_BUILD_BUILDER
    receipt_owner=1
  fi
  python3 "$project_dir/docker/build_cleanup.py" validate --root "$project_dir" --work "$RECEIPT_BUILD_WORK"
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$RECEIPT_BUILD_WORK/tmp"
  export TMPDIR="$RECEIPT_BUILD_WORK/tmp"
  trap 'receipt_build_finish "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
receipt_builder_start() {
  if [[ -z "$RECEIPT_BUILD_BUILDER" ]]; then
    RECEIPT_BUILD_BUILDER="receipt-master-$(id -u)-$$"
    docker buildx create --name "$RECEIPT_BUILD_BUILDER" --driver docker-container >/dev/null
    export RECEIPT_BUILD_BUILDER
  fi
}
receipt_docker_build() {
  receipt_builder_start
  docker buildx build --builder "$RECEIPT_BUILD_BUILDER" "$@"
}
receipt_target_inputs() {
  receipt_target="$1"
  shift
  receipt_state=(python3 "$project_dir/docker/build_state.py")
  receipt_inputs=(--root "$project_dir")
  local item
  for item in docker/build_state.py docker/build_lifecycle.sh docker/build_cleanup.py "$@"; do
    receipt_inputs+=(--input "$item")
  done
  receipt_key="$("${receipt_state[@]}" fingerprint "${receipt_inputs[@]}")"
}
receipt_target_probe() {
  receipt_outputs=()
  local item
  for item in "$@"; do receipt_outputs+=(--output "$item"); done
  if [[ ${RECEIPT_REFRESH_BUILD:-0} == 1 ]]; then
    receipt_reuse=""
    return
  fi
  receipt_reuse="$("${receipt_state[@]}" probe --root "$project_dir" --target "$receipt_target" --key "$receipt_key" "${receipt_outputs[@]}")"
}
receipt_target_record() {
  "${receipt_state[@]}" record --root "$project_dir" --target "$receipt_target" --key "$receipt_key" "${receipt_outputs[@]}" "$@"
}
receipt_build_finish() {
  local result="$1"
  trap - EXIT INT TERM
  if [[ "$result" == 0 ]]; then
    if [[ "$receipt_owner" == 1 && -n "$RECEIPT_BUILD_BUILDER" ]]; then
      if docker buildx rm "$RECEIPT_BUILD_BUILDER"; then
        RECEIPT_BUILD_BUILDER=""
      else
        result=$?
      fi
    fi
    if [[ "$result" == 0 ]]; then
      python3 "$project_dir/docker/build_cleanup.py" clean --root "$project_dir" \
        --work "$RECEIPT_BUILD_WORK" --component "$receipt_component" --owner "$receipt_owner" || result=$?
    fi
  fi
  if [[ "$result" != 0 ]]; then
    echo "Build or cleanup failed; diagnostics retained: $RECEIPT_BUILD_WORK" >&2
    if [[ -n "$RECEIPT_BUILD_BUILDER" ]]; then
      echo "Build cache retained in builder: $RECEIPT_BUILD_BUILDER" >&2
    fi
  fi
  exit "$result"
}
