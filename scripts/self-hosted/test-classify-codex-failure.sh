#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
helper="${script_dir}/classify-codex-failure.sh"
test_root="${TMPDIR:-/tmp}/codex-failure-classifier-${RANDOM}-${RANDOM}"
mkdir -p "$test_root"
trap 'rm -rf -- "$test_root"' EXIT

expect_code() {
  local name="$1" expected="$2" text="$3" actual
  printf '%s\n' "$text" > "${test_root}/${name}.stderr"
  actual="$(bash "$helper" "${test_root}/${name}.stderr")"
  [[ "$actual" == "$expected" ]]
}

expect_code auth CODEX_AUTH_FAILED 'authentication was rejected'
expect_code token_expired CODEX_AUTH_FAILED 'expired access token'
expect_code token_limit CODEX_MODEL_OR_SERVICE_FAILED 'context token limit reached'
expect_code token_budget CODEX_MODEL_OR_SERVICE_FAILED 'token budget exceeded'
expect_code model CODEX_MODEL_OR_SERVICE_FAILED 'model service unavailable'
expect_code network CODEX_NETWORK_OR_TRANSPORT_FAILED 'network connection timed out'
expect_code sandbox CODEX_SANDBOX_OR_PERMISSION_FAILED 'sandbox permission denied'
expect_code cli CODEX_CLI_OR_CONFIGURATION_FAILED 'unknown option --bad'
expect_code generic CODEX_EXECUTION_FAILED 'process failed without a supported diagnostic'
[[ "$(bash "$helper" "${test_root}/missing.stderr")" == CODEX_EXECUTION_FAILED ]]

printf '%s\n' 'Codex failure classifier tests passed'
