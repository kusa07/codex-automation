#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
entrypoint="${script_dir}/manage-execution-area.sh"
test_root="${TEMP:-${TMP:-/tmp}}/codex-managed-area-test-${RANDOM}-${RANDOM}"
reparse_target="${test_root}-reparse-target"

cleanup() { rm -rf -- "$test_root" "$reparse_target"; }
trap cleanup EXIT

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    printf 'expected failure did not occur: %s\n' "$*" >&2
    exit 1
  fi
}

reset_area() {
  rm -rf -- "$test_root"
  "$entrypoint" ensure >/dev/null
}

marker_before=''

export CODEX_AUTOMATION_ROOT="$test_root"
mkdir -p -- "$test_root"
expect_failure "$entrypoint" ensure
rm -rf -- "$test_root"
"$entrypoint" ensure >/dev/null
"$entrypoint" preflight >/dev/null
"$entrypoint" preflight >/dev/null

marker_before="$(cat -- "$test_root/.codex-automation-managed")"

rm -rf -- "$test_root/temp"
"$entrypoint" ensure >/dev/null
test -d "$test_root/temp"
test "$marker_before" = "$(cat -- "$test_root/.codex-automation-managed")"

rm -f -- "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight
reset_area

printf '{malformed' > "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight
"$entrypoint" ensure >/dev/null 2>&1 && exit 1 || true

reset_area
printf '%s\n' '{"managed_by":"other","schema":1,"execution_area_id":"11111111-1111-4111-8111-111111111111","created_at":"2026-01-01T00:00:00.0000000Z"}' > "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight

reset_area
printf '%s\n' '{"managed_by":"codex-automation","schema":1.4,"execution_area_id":"11111111-1111-4111-8111-111111111111","created_at":"2026-01-01T00:00:00.0000000Z"}' > "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight

reset_area
printf '%s\n' '{"managed_by":"codex-automation","schema":"1","execution_area_id":"11111111-1111-4111-8111-111111111111","created_at":"2026-01-01T00:00:00.0000000Z"}' > "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight

reset_area
printf '%s\n' '{"managed_by":"codex-automation","schema":2,"execution_area_id":"11111111-1111-4111-8111-111111111111","created_at":"2026-01-01T00:00:00.0000000Z"}' > "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight

reset_area
printf '%s\n' '{"managed_by":"codex-automation","schema":1,"execution_area_id":"not-a-guid","created_at":"2026-01-01T00:00:00.0000000Z"}' > "$test_root/.codex-automation-managed"
expect_failure "$entrypoint" preflight

reset_area
printf '{}' > "$test_root/state/current-run.json"
expect_failure "$entrypoint" preflight

rm -f -- "$test_root/state/current-run.json"
printf residue > "$test_root/temp/residue.tmp"
expect_failure "$entrypoint" preflight

reset_area
printf residue > "$test_root/codex-home/auth.json"
expect_failure "$entrypoint" preflight

reset_area
printf residue > "$test_root/temp/.atomic.tmp"
expect_failure "$entrypoint" preflight

reset_area
printf residue > "$test_root/.codex-automation-managed.test.tmp"
expect_failure "$entrypoint" preflight

reset_area
printf unexpected > "$test_root/unexpected.txt"
expect_failure "$entrypoint" preflight

reset_area
rm -rf -- "$test_root/temp" "$reparse_target"
if pwsh -NoLogo -NoProfile -NonInteractive -Command "New-Item -ItemType Directory -Path '$reparse_target' -Force -ErrorAction Stop | Out-Null; New-Item -ItemType Junction -Path (Join-Path '$test_root' 'temp') -Target '$reparse_target' -ErrorAction Stop | Out-Null" >/dev/null 2>&1; then
  expect_failure "$entrypoint" preflight
  printf 'reparse-point negative path passed\n'
else
  printf 'reparse-point negative path unavailable on this host\n'
fi

printf 'managed execution area negative-path tests passed\n'
