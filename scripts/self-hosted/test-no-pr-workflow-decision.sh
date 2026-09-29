#!/usr/bin/env bash
set -euo pipefail

# Execute the actual general-Issue decision block extracted from the immutable
# reusable workflow. External GitHub posting is separately mocked by the
# production no-pr-result.ps1 helper test; this fixture covers the stage
# helper -> zero-change branch -> structured Prepare call without a shortcut.
automation_source="${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
workflow="${automation_source}/.github/workflows/codex-run.yml"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-no-pr-decision.XXXXXX")"
case "${test_root}" in */codex-no-pr-decision.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "${test_root}"' EXIT
decision="${test_root}/decision.sh"
awk '
  /^            stage_status=0$/ { in_decision=1 }
  in_decision {
    final_line=($0 ~ /^            \(\( stage_status == 0 \)\) \|\| exit "\$\{stage_status\}"$/)
    sub(/^            /, ""); print
    if (final_line) exit
  }
' "${workflow}" > "${decision}"
[[ -s "${decision}" ]]
grep -Fqx '(( stage_status == 0 )) || exit "${stage_status}"' "${decision}"
bash -n "${decision}"

trusted_auth="${test_root}/auth-source"
printf '%s' 'synthetic-test-auth-only' > "${trusted_auth}"
GITHUB_REPOSITORY='owner/repo'
GITHUB_REPOSITORY_ID=123
ISSUE_NUMBER=25
GITHUB_RUN_ID=567
GITHUB_RUN_ATTEMPT=1
execution_id='repo-123-run-567-attempt-1'
owner_nonce='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
secret_file="${trusted_auth}"

next_repo=0
new_repo() {
  next_repo=$((next_repo + 1))
  workspace_path="${test_root}/workspace-${next_repo}"
  mkdir -p -- "${workspace_path}"
  git -C "${workspace_path}" init -q
  git -C "${workspace_path}" config user.name test
  git -C "${workspace_path}" config user.email test@example.invalid
  printf '%s\n' baseline > "${workspace_path}/README.md"
  git -C "${workspace_path}" add -- README.md
  git -C "${workspace_path}" commit -qm baseline
  base_sha="$(git -C "${workspace_path}" rev-parse HEAD)"
  printf '%s\n' "synthetic-marker-${next_repo}" > "${workspace_path}/.codex-workspace-owned.json"
  expected_marker_hash="$(sha256sum -- "${workspace_path}/.codex-workspace-owned.json" | cut -d ' ' -f 1)"
  result_file="${test_root}/result-${next_repo}.json"
  no_pr_candidate_file="${test_root}/candidate-${next_repo}.json"
  PAYLOAD_STATUS_FILE="${test_root}/status-${next_repo}"
}
run_decision() {
  export automation_source workspace_path secret_file expected_marker_hash
  export no_pr_candidate_file result_file GITHUB_REPOSITORY GITHUB_REPOSITORY_ID
  export ISSUE_NUMBER GITHUB_RUN_ID GITHUB_RUN_ATTEMPT execution_id owner_nonce
  export base_sha PAYLOAD_STATUS_FILE
  bash "${decision}"
}

new_repo
printf '%s' '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Already complete."}' > "${result_file}"
run_decision
[[ -f "${no_pr_candidate_file}" && "$(<"${PAYLOAD_STATUS_FILE}")" == PASS ]]
CODEX_TEST_CANDIDATE="$(cygpath -aw -- "${no_pr_candidate_file}")" pwsh -NoProfile -NonInteractive -Command '
  $c=Get-Content -LiteralPath $env:CODEX_TEST_CANDIDATE -Raw | ConvertFrom-Json
  if($c.result -cne "NO_CHANGES" -or $c.reason_code -cne "NO_CHANGE_NEEDED" -or $c.execution_id -cne "repo-123-run-567-attempt-1") { exit 1 }
'

new_repo
printf '%s' '{"outcome":"STOP_AND_REPORT","reason_code":"REQUIRES_USER_DECISION","summary":"A user decision is needed."}' > "${result_file}"
run_decision
CODEX_TEST_CANDIDATE="$(cygpath -aw -- "${no_pr_candidate_file}")" pwsh -NoProfile -NonInteractive -Command '
  $c=Get-Content -LiteralPath $env:CODEX_TEST_CANDIDATE -Raw | ConvertFrom-Json
  if($c.result -cne "STOP_AND_REPORT" -or $c.reason_code -cne "REQUIRES_USER_DECISION") { exit 1 }
'

new_repo
printf '%s\n' changed > "${workspace_path}/README.md"
printf '%s' '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Model claimed no changes."}' > "${result_file}"
run_decision
[[ ! -e "${no_pr_candidate_file}" && ! -e "${PAYLOAD_STATUS_FILE}" ]]
[[ "$(git -C "${workspace_path}" diff --cached --name-only)" == README.md ]]

new_repo
printf '%s\n' changed > "${workspace_path}/README.md"
printf '%s\n' second > "${workspace_path}/second.txt"
printf '%s' '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Model claimed no changes."}' > "${result_file}"
run_decision
[[ ! -e "${no_pr_candidate_file}" && "$(git -C "${workspace_path}" diff --cached --name-only | wc -l | tr -d ' ')" == 2 ]]

new_repo
mkdir -p -- "${workspace_path}/.github/workflows"
printf '%s\n' unsafe > "${workspace_path}/.github/workflows/unsafe.yml"
printf '%s' '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"No change."}' > "${result_file}"
if run_decision >/dev/null 2>&1; then
  echo 'Protected path unexpectedly reached no-PR return.' >&2
  exit 1
fi
[[ ! -e "${no_pr_candidate_file}" ]]

grep -Fq "steps.workspace_cleanup.outputs.no_pr_ready == 'true'" "${workflow}"
grep -Fq "steps.gcloud_cleanup.outcome == 'success'" "${workflow}"
grep -Fq 'if: ${{ success() && steps.workspace_cleanup.outputs.no_pr_ready' "${workflow}"
printf '%s\n' 'Production-shaped no-PR workflow decision tests passed'
