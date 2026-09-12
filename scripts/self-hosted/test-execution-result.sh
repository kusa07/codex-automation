#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
helper="${script_dir}/execution-result.sh"

expect_result() {
  local code="$1" expected_class="$2" expected_action="$3" output
  output="$(bash "$helper" emit --code "$code")"
  grep -Fx "RESULT_CLASS=${expected_class}" <<<"$output" >/dev/null
  grep -Fx "RESULT_CODE=${code}" <<<"$output" >/dev/null
  grep -Fx "RESULT_SAFE_ACTION=${expected_action}" <<<"$output" >/dev/null
  grep -Eq '^RESULT_CAUSE=[^[:cntrl:]]+$' <<<"$output"
  grep -Eq '^RESULT_PRESERVED_STATE=[^[:cntrl:]]+$' <<<"$output"
  ! grep -Eqi 'token|secret payload|auth\.json|credential value' <<<"$output"
}

expect_result SUCCESS SUCCESS USER_REVIEW
expect_result RUNNER_OFFLINE INFRASTRUCTURE_RUNNER RETRY
expect_result RUNNER_BUSY INFRASTRUCTURE_RUNNER RETRY
expect_result RUNNER_INELIGIBLE INFRASTRUCTURE_RUNNER RETRY
expect_result UNKNOWN_INFRASTRUCTURE_FAILURE INFRASTRUCTURE_RUNNER RETRY
expect_result SELF_HOSTED_PREFLIGHT_FAILED INFRASTRUCTURE_RUNNER RECOVER_THEN_RETRY
expect_result SELF_HOSTED_LOCK_ABANDONED INFRASTRUCTURE_RUNNER RECOVER_THEN_RETRY
expect_result SELF_HOSTED_STATE_INVALID INFRASTRUCTURE_RUNNER RECOVER_THEN_RETRY
expect_result SELF_HOSTED_CLEANUP_FAILED INFRASTRUCTURE_RUNNER RECOVER_THEN_RETRY
expect_result OIDC_AUTH_FAILED AUTHENTICATION_SECRET RETRY
expect_result SECRET_READ_FAILED AUTHENTICATION_SECRET RETRY
expect_result CODEX_AUTH_FAILED AUTHENTICATION_SECRET USER_DECISION
expect_result SECRET_STATE_AMBIGUOUS AUTHENTICATION_SECRET USER_DECISION
expect_result SECRET_WRITE_FAILED AUTHENTICATION_SECRET RECOVER_THEN_RETRY
expect_result SECRET_VERIFY_FAILED AUTHENTICATION_SECRET RECOVER_THEN_RETRY
expect_result CODEX_MODEL_OR_SERVICE_FAILED CODEX_MODEL RETRY
expect_result CODEX_NETWORK_OR_TRANSPORT_FAILED CODEX_MODEL RETRY
expect_result CODEX_SANDBOX_OR_PERMISSION_FAILED CODEX_MODEL RETRY
expect_result CODEX_CLI_OR_CONFIGURATION_FAILED CODEX_MODEL RETRY
expect_result CODEX_EXECUTION_FAILED CODEX_MODEL RETRY
expect_result WORKSPACE_VALIDATION_FAILED WORKSPACE_GITHUB_PUBLICATION RECOVER_THEN_RETRY
expect_result GITHUB_PUBLISH_FAILED WORKSPACE_GITHUB_PUBLICATION RECOVER_THEN_RETRY
expect_result UNKNOWN_FAILURE UNKNOWN USER_DECISION

if bash "$helper" emit --code NOT_A_RESULT >/dev/null 2>&1; then
  printf '%s\n' 'unsupported result code was accepted' >&2
  exit 1
fi
if bash "$helper" emit --code CODEX_AUTH_FAILED extra >/dev/null 2>&1; then
  printf '%s\n' 'unexpected arguments were accepted' >&2
  exit 1
fi
workflow="${script_dir}/../../.github/workflows/codex-run.yml"
grep -F 'execution-result.sh" emit --code "${result_code}"' "$workflow" >/dev/null
grep -F "result_code='SECRET_STATE_AMBIGUOUS'" "$workflow" >/dev/null
grep -F "result_code='SELF_HOSTED_CLEANUP_FAILED'" "$workflow" >/dev/null
grep -F "result_code='SUCCESS'" "$workflow" >/dev/null
grep -F 'if ! gcloud secrets versions list' "$workflow" >/dev/null
grep -F "result_code='SECRET_READ_FAILED'" "$workflow" >/dev/null
grep -F 'enabled_versions_file' "$workflow" >/dev/null
grep -F 'set +e' "$workflow" >/dev/null
grep -F 'cleanup_failed=1' "$workflow" >/dev/null
printf '%s\n' 'execution result contract tests passed'
