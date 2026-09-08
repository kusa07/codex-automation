#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' 'FAIL_CLOSED'
  exit 1
}

[[ "$#" == 1 ]] || fail
[[ "${WORKFLOW_SOURCE_REPOSITORY:-}" == 'kusa07/codex-automation' ]] || fail
[[ "${WORKFLOW_SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail
[[ "${EXECUTION_REPOSITORY_ID:-}" =~ ^[0-9]+$ ]] || fail
[[ "${EXECUTION_RUN_ID:-}" =~ ^[0-9]+$ ]] || fail
[[ "${EXECUTION_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || fail

source_dir="$(cygpath -u -- "$1" 2>/dev/null)" || fail
actual_sha="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)" || fail
[[ "$actual_sha" == "$WORKFLOW_SOURCE_SHA" ]] || fail

capture_sanitized() {
  local status output line normalized
  if output="$("$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  while IFS= read -r line; do
    normalized="${line%$'\r'}"
    case "$normalized" in
      PREFLIGHT_PASSED|LOCK_ACQUIRED|EXECUTION_STARTED|CLEANUP_PASSED|EXECUTION_FINISHED|ABANDONED_LOCK_DETECTED|FAIL_CLOSED)
        printf '%s\n' "$normalized"
        ;;
      '') ;;
      *) fail ;;
    esac
  done <<< "$output"
  (( status == 0 )) || fail
}

"$source_dir/scripts/self-hosted/manage-execution-area.sh" ensure >/dev/null 2>&1 || fail
printf '%s\n' 'PREFLIGHT_PASSED'
capture_sanitized "$source_dir/scripts/self-hosted/run-local-execution.sh" run \
  --repository-id "$EXECUTION_REPOSITORY_ID" \
  --run-id "$EXECUTION_RUN_ID" \
  --attempt "$EXECUTION_RUN_ATTEMPT" \
  --inert
