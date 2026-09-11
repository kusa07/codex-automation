#!/usr/bin/env bash
# Emit the small, sanitized Phase 11 result contract.  This helper never
# accepts raw stderr, task input, repository content, or credential material.
set -euo pipefail

usage() {
  printf '%s\n' 'usage: execution-result.sh emit --code CODE' >&2
  exit 64
}

[[ "${1:-}" == emit && "${2:-}" == --code && $# == 3 ]] || usage
code="$3"

result_class=''
cause=''
preserved_state=''
action=''
case "$code" in
  SUCCESS)
    result_class='SUCCESS'
    cause='validated execution completed'
    preserved_state='validated result is available for review'
    action='USER_REVIEW'
    ;;
  RUNNER_OFFLINE|RUNNER_BUSY|RUNNER_INELIGIBLE|UNKNOWN_INFRASTRUCTURE_FAILURE)
    result_class='INFRASTRUCTURE_RUNNER'
    cause='runner availability or infrastructure did not permit execution'
    preserved_state='no Local Codex task or publication was started'
    action='RETRY'
    ;;
  SELF_HOSTED_PREFLIGHT_FAILED|SELF_HOSTED_LOCK_ABANDONED|SELF_HOSTED_STATE_INVALID|SELF_HOSTED_CLEANUP_FAILED)
    result_class='INFRASTRUCTURE_RUNNER'
    cause='managed execution area requires verified recovery'
    preserved_state='unknown execution-area state was not deleted automatically'
    action='RECOVER_THEN_RETRY'
    ;;
  OIDC_AUTH_FAILED|SECRET_READ_FAILED)
    result_class='AUTHENTICATION_SECRET'
    cause='required temporary authentication material was unavailable'
    preserved_state='known-good Secret state was not modified'
    action='RETRY'
    ;;
  CODEX_AUTH_FAILED)
    result_class='AUTHENTICATION_SECRET'
    cause='stored Codex authentication was not accepted'
    preserved_state='known-good Secret state was not replaced'
    action='USER_DECISION'
    ;;
  SECRET_WRITE_FAILED|SECRET_VERIFY_FAILED)
    result_class='AUTHENTICATION_SECRET'
    cause='authentication candidate was not safely adopted'
    preserved_state='previous authoritative Secret version remains recoverable'
    action='RECOVER_THEN_RETRY'
    ;;
  CODEX_MODEL_OR_SERVICE_FAILED|CODEX_NETWORK_OR_TRANSPORT_FAILED|CODEX_SANDBOX_OR_PERMISSION_FAILED|CODEX_CLI_OR_CONFIGURATION_FAILED|CODEX_EXECUTION_FAILED)
    result_class='CODEX_MODEL'
    cause='Local Codex execution did not complete'
    preserved_state='unvalidated changes were not published'
    action='RETRY'
    ;;
  WORKSPACE_VALIDATION_FAILED|GITHUB_PUBLISH_FAILED)
    result_class='WORKSPACE_GITHUB_PUBLICATION'
    cause='workspace validation or trusted publication did not complete'
    preserved_state='recoverable branch and commit state was retained when created'
    action='RECOVER_THEN_RETRY'
    ;;
  UNKNOWN_FAILURE)
    result_class='UNKNOWN'
    cause='no supported sanitized failure classification was available'
    preserved_state='no automatic recovery was performed'
    action='USER_DECISION'
    ;;
  *)
    printf '%s\n' 'unsupported execution result code' >&2
    exit 64
    ;;
esac

printf 'RESULT_CLASS=%s\n' "$result_class"
printf 'RESULT_CODE=%s\n' "$code"
printf 'RESULT_CAUSE=%s\n' "$cause"
printf 'RESULT_PRESERVED_STATE=%s\n' "$preserved_state"
printf 'RESULT_SAFE_ACTION=%s\n' "$action"
