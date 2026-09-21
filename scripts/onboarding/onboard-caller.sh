#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/../lib/phase12b-config.sh"
usage() { echo "Usage: $0 --environment FILE --caller FILE [--retired-caller FILE] [--mode plan|apply --approve] [test only: --test-mode --fixture-root DIR]"; }
[[ -z "${PHASE12B_TEST_MODE:-}${PHASE12B_TEST_ROOT:-}${PHASE12B_INTERNAL_TEST_MODE:-}${PHASE12B_INTERNAL_TEST_ROOT:-}" ]] || { echo 'Environment-based test activation is prohibited.' >&2; exit 3; }
mode=plan; approval=''; environment=''; caller=''; retired_caller=''; test_mode=false; fixture_root=''
while [[ $# -gt 0 ]]; do case "$1" in
  --environment) environment="${2:-}"; shift 2;; --caller) caller="${2:-}"; shift 2;; --retired-caller) retired_caller="${2:-}"; shift 2;;
  --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; --test-mode) test_mode=true; shift;; --fixture-root) fixture_root="${2:-}"; shift 2;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ -n "$environment" && -n "$caller" ]] || { usage >&2; exit 2; }
$test_mode && phase12b_enable_test_mode "$fixture_root"
if phase12b_test_mode; then phase12b_assert_test_file_path "$environment" environment;phase12b_assert_test_file_path "$caller" caller;[[ -z "$retired_caller" ]] || phase12b_assert_test_file_path "$retired_caller" retired-caller;fi
phase12b_plan_or_apply "$mode" "$approval"; phase12b_require_yaml_file "$environment"; phase12b_require_yaml_file "$caller"; phase12b_validate_environment "$environment"; phase12b_validate_caller "$caller"
repo="$(phase12b_yaml_value "$caller" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$caller" '.repository.id')"; secret="$(phase12b_yaml_value "$caller" '.secret.id')"; branch="$(phase12b_yaml_value "$caller" '.workflow.branch')"
sha="$(phase12b_yaml_value "$environment" '.automation.active_workflow_sha')"; project_id="$(phase12b_yaml_value "$environment" '.google_cloud.project_id')"; project_number="$(phase12b_yaml_value "$environment" '.google_cloud.project_number')"; pool="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_pool')";iam_member="principalSet://iam.googleapis.com/projects/$project_number/locations/global/workloadIdentityPools/$pool/attribute.repository_id/$repo_id"
phase12b_require_secret_id "$secret"; phase12b_require_sha "$sha"
host_config=''; host_inspect=''
if ! phase12b_test_mode; then
  phase12b_reject_production_test_injections PHASE12B_GH_BIN PHASE12B_GCLOUD_BIN PHASE12B_RUNNER_STATE PHASE12B_SERVICE_STATE PHASE12B_ADD_CALLER_SCRIPT PHASE12B_RUNNER_APPLY PHASE12B_SERVICE_APPLY PHASE12B_WORKFLOW_APPLY PHASE12B_VERIFY PHASE12B_RESTORE_ADAPTER PHASE12B_REONBOARD_AUTH_CHECK PHASE12B_REONBOARD_VERSION_ID || exit $?
fi
host_config="$(phase12b_resolve_host_config "$environment")"
host_inspect="$(phase12b_caller_runner Inspect "$host_config" "$repo" "$repo_id")" || { echo 'Canonical host Inspect failed.' >&2; exit 3; }
if phase12b_test_mode; then fixture_bin="$(phase12b_test_fixture_root)/bin";gh_bin="$fixture_bin/gh";gcloud_bin="$fixture_bin/gcloud";[[ -x "$gh_bin" && -x "$gcloud_bin" && ! -L "$gh_bin" && ! -L "$gcloud_bin" ]] || { echo 'Fixed test read-back fixtures are missing or unsafe.' >&2; exit 3; };else gh_bin=gh;gcloud_bin=gcloud;command -v "$gh_bin" >/dev/null 2>&1 || { echo 'gh is required for repository grounding.' >&2; exit 127; };command -v "$gcloud_bin" >/dev/null 2>&1 || { echo 'gcloud is required for caller grounding.' >&2; exit 127; };fi
phase12b_validate_secret_authentication() (
  local version="$1" auth_root
  auth_root="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$auth_root"' EXIT HUP INT TERM
  chmod 700 "$auth_root" 2>/dev/null || true
  "$gcloud_bin" secrets versions access "$version" --secret="$secret" --project="$project_id" --out-file="$auth_root/auth.json" >/dev/null 2>&1 || return 1
  command -v codex >/dev/null 2>&1 || return 1
  CODEX_HOME="$auth_root" HOME="$auth_root" USERPROFILE="$auth_root" codex login status >/dev/null 2>&1
)
actual_repo_id="$("$gh_bin" repo view "$repo" --json databaseId --jq '.databaseId' 2>/dev/null || true)"
[[ "$actual_repo_id" =~ ^[1-9][0-9]*$ && "$actual_repo_id" == "$repo_id" ]] || { echo 'Repository ID read-back did not match desired state.' >&2; exit 3; }
default_branch="$("$gh_bin" repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
[[ "$default_branch" == "$branch" ]] || { echo 'Repository default branch does not match desired caller workflow branch.' >&2; exit 3; }
workflow_state="$(phase12b_github_content_state "$gh_bin" "repos/$repo/contents/$(phase12b_yaml_value "$caller" '.workflow.path')?ref=$branch")" || exit $?
secret_state="$($gcloud_bin secrets list --project="$project_id" --filter="name=$secret" --format='value(name)')" || { echo 'Unable to read Secret inventory.' >&2; exit 3; }
if [[ -n "$secret_state" ]]; then
  secret_action=VERIFY_EXISTING
  secret_versions_state="$($gcloud_bin secrets versions list "$secret" --project="$project_id" --format='json(name,state)' 2>/dev/null)" || { echo 'Unable to read Secret version metadata.' >&2; exit 3; }
  iam_state="$($gcloud_bin secrets get-iam-policy "$secret" --project="$project_id" --format='json(bindings)' 2>/dev/null)" || { echo 'Unable to read Secret IAM metadata.' >&2; exit 3; }
else
  # Only a successful inventory query with no exact result proves ABSENT.
  # Version and IAM APIs are intentionally not called for a resource that does
  # not exist; creation remains behind the consolidated approval below.
  secret_state=ABSENT; secret_action=CREATE; secret_versions_state=NOT_APPLICABLE_UNTIL_CREATED; iam_state=NOT_APPLICABLE_UNTIL_CREATED
fi
runner_state=AUTHORITATIVE_HOST_READBACK_REQUIRED; service_state=AUTHORITATIVE_HOST_READBACK_REQUIRED
if [[ -n "$host_inspect" ]]; then runner_state="$(sed -n 's/^CALLER_RUNNER_SNAPSHOT_STATE=//p' <<< "$host_inspect")"; service_state="$(sed -n 's/^SERVICE_STATE=//p' <<< "$host_inspect")"; [[ -n "$runner_state" && -n "$service_state" ]] || { echo 'Canonical host Inspect output is incomplete.' >&2; exit 3; }; fi

lifecycle=NEW; reonboard_state=NOT_APPLICABLE; retired_version=''; retired_repo_id=''; retired_repo=''; retired_secret=''
if [[ -n "$retired_caller" ]]; then
  phase12b_require_yaml_file "$retired_caller"; phase12b_validate_retired_caller "$retired_caller"
  retired_repo="$(phase12b_yaml_value "$retired_caller" '.repository.full_name')"; retired_repo_id="$(phase12b_yaml_value "$retired_caller" '.repository.id')"; retired_secret="$(phase12b_yaml_value "$retired_caller" '.secret.id')"; retired_version="$(phase12b_yaml_value "$retired_caller" '.lifecycle.last_authoritative_secret_version')"; retired_state="$(phase12b_yaml_value "$retired_caller" '.lifecycle.state')"
  if [[ "$retired_repo_id" != "$repo_id" || "$retired_secret" != "$secret" || "$retired_state" != retired ]]; then lifecycle=IDENTITY_CONFLICT; else lifecycle=RETIRED_MATCH; fi
  phase12b_require_numeric_version "$retired_version" >/dev/null || lifecycle=IDENTITY_CONFLICT
  # Retired desired-state metadata is the only version authority.  Reject any
  # legacy environment version input, even when it happens to agree.
  [[ -z "${PHASE12B_REONBOARD_VERSION_ID:-}" ]] || lifecycle=IDENTITY_CONFLICT
fi
if [[ "$lifecycle" == RETIRED_MATCH ]]; then
  if ! secret_resource="$("$gcloud_bin" secrets describe "$secret" --project="$project_id" --format='value(name)' 2>/dev/null)"; then
    echo 'Unable to read retired Secret identity.' >&2; exit 3
  fi
  [[ "$secret_resource" =~ /secrets/$secret$ ]] || { echo 'Actual Secret identity does not match retired desired state.' >&2; exit 3; }
  if ! version_metadata="$("$gcloud_bin" secrets versions describe "$retired_version" --secret="$secret" --project="$project_id" --format='value(name,state)' 2>/dev/null)"; then
    echo 'Unable to read retired authoritative Secret version.' >&2; exit 3
  fi
  IFS=$'\t' read -r actual_version_resource version_state <<< "$version_metadata"
  [[ "$actual_version_resource" =~ /versions/$retired_version$ ]] || { echo 'Actual Secret version identity does not match retired desired state.' >&2; exit 3; }
  if ! enabled="$("$gcloud_bin" secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)' 2>/dev/null)"; then
    echo 'Unable to read enabled Secret versions for re-onboard.' >&2; exit 3
  fi
  enabled_count="$(phase12b_nonblank_line_count "$enabled")"
  auth_valid=false
  if [[ -n "${PHASE12B_REONBOARD_AUTH_CHECK:-}" ]]; then
    phase12b_test_mode || { echo 'Environment-injected re-onboard authentication check is test-only.' >&2; exit 3; }
    auth_check="$(phase12b_test_adapter_path PHASE12B_REONBOARD_AUTH_CHECK)"
    "$auth_check" --repository-id "$repo_id" --secret-id "$secret" --version "$retired_version" >/dev/null && auth_valid=true
  fi
  if ! phase12b_test_mode && [[ "$repo_id" == "$actual_repo_id" && "$secret" == "$retired_secret" && "$version_state" == DISABLED && "$enabled_count" == 0 ]]; then
    reonboard_state=AUTH_VALIDATION_REQUIRED
  else
    reonboard_state="$(phase12b_classify_reonboard "$repo_id" "$actual_repo_id" "$secret" "$retired_secret" "$retired_version" true "$version_state" "$auth_valid" "$enabled_count")"
  fi
fi
printf 'ONBOARD_PLAN=PASS\nREPOSITORY=%s\nREPOSITORY_ID=%s\nCALLER_LIFECYCLE=%s\nREONBOARD_STATE=%s\nSECRET_ID=%s\nSECRET_ACTION=%s\nWORKFLOW_SHA=%s\nWORKFLOW_BRANCH=%s\nSECRET_STATE=%s\nSECRET_VERSION_METADATA=%s\nIAM_STATE=%s\nRUNNER_STATE=%s\nWINDOWS_SERVICE_STATE=%s\nMODE=%s\n' "$repo" "$repo_id" "$lifecycle" "$reonboard_state" "$secret" "$secret_action" "$sha" "$branch" "$secret_state" "$secret_versions_state" "$iam_state" "$runner_state" "$service_state" "$mode"
phase12b_audit ONBOARD_PLAN "$repo" "$mode"
[[ "$lifecycle" != IDENTITY_CONFLICT ]] || { echo 'Caller lifecycle identity conflict is fail-closed.' >&2; exit 3; }
[[ "$mode" == plan ]] && exit 0
[[ "${PHASE12B_APPROVAL_TOKEN:-}" == approve-onboard || "$approval" == --approve ]] || { echo 'Approval token missing.' >&2; exit 2; }
if ! phase12b_test_mode; then
  if [[ "$lifecycle" == RETIRED_MATCH ]]; then
    [[ "$reonboard_state" == AUTH_VALIDATION_REQUIRED ]] || { echo 'Re-onboarding requires exact retired metadata and pending actual authentication validation.' >&2; exit 3; }
    "$gcloud_bin" secrets versions enable "$retired_version" --secret="$secret" --project="$project_id" --quiet >/dev/null
    enabled_restored="$($gcloud_bin secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)')" || { echo 'Unable to read restored Secret version.' >&2; exit 3; }
    [[ "$(phase12b_nonblank_line_count "$enabled_restored")" == 1 && "$enabled_restored" =~ /versions/$retired_version$ ]] || { echo 'Restored Secret version postcondition failed.' >&2; exit 3; }
    if ! phase12b_validate_secret_authentication "$retired_version"; then
      "$gcloud_bin" secrets versions disable "$retired_version" --secret="$secret" --project="$project_id" --quiet >/dev/null 2>&1 || true
      rollback_enabled="$($gcloud_bin secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)' 2>/dev/null)" || { echo 'Authentication validation failed and rollback read-back failed.' >&2; exit 3; }
      rollback_state="$($gcloud_bin secrets versions describe "$retired_version" --secret="$secret" --project="$project_id" --format='value(state)' 2>/dev/null)" || { echo 'Authentication validation failed and exact-version rollback state is unknown.' >&2; exit 3; }
      [[ "$(phase12b_nonblank_line_count "$rollback_enabled")" == 0 && "$rollback_state" == DISABLED ]] || { echo 'Authentication validation failed and exact-version rollback did not complete.' >&2; exit 3; }
      echo 'Actual authentication validation failed; re-onboard stopped.' >&2; exit 3
    fi
    reonboard_state=RESTORE_CANDIDATE
  fi
  "$SCRIPT_DIR/../google-cloud/add-caller.sh" --project-id "$project_id" --repository-id "$repo_id" --secret-id "$secret" --pool-id "$pool"
  secret_ready="$($gcloud_bin secrets describe "$secret" --project="$project_id" --format='value(name)' 2>/dev/null)" || { echo 'Unable to read Secret identity after preparation.' >&2; exit 3; }
  [[ "$secret_ready" =~ /secrets/$secret$ ]] || { echo 'Secret creation/read-back postcondition failed.' >&2; exit 3; }
  enabled_ready="$($gcloud_bin secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)')" || { echo 'Unable to read enabled Secret version after preparation.' >&2; exit 3; }
  [[ "$(phase12b_nonblank_line_count "$enabled_ready")" == 1 && "$enabled_ready" =~ /versions/[1-9][0-9]*$ ]] || { echo 'Onboarding requires exactly one enabled numeric Secret version before runner/workflow activation.' >&2; exit 3; }
  iam_ready="$($gcloud_bin secrets get-iam-policy "$secret" --project="$project_id" --flatten='bindings[].members' --format='value(bindings.role,bindings.members)')" || { echo 'Unable to read Secret IAM after preparation.' >&2; exit 3; }
  phase12b_secret_iam_exact "$iam_ready" "$iam_member" || { echo 'Secret IAM exact role/member postcondition failed.' >&2; exit 3; }
  phase12b_caller_runner Onboard "$host_config" "$repo" "$repo_id"
  "$SCRIPT_DIR/sync-caller-workflow.sh" --repository "$repo" --environment "$environment" --private-config "$caller" --target-workflow-sha "$sha" --mode apply --approve
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$SCRIPT_DIR/../host/verify-host.ps1" -PrivateConfig "$environment"
  phase12b_audit ONBOARD_APPLY "$repo" apply; echo 'ONBOARD_APPLY=PASS'; exit 0
fi
if [[ "$lifecycle" == RETIRED_MATCH ]]; then [[ "$reonboard_state" == RESTORE_CANDIDATE ]] || { echo 'Re-onboarding requires retired metadata-backed restore candidate.' >&2; exit 3; }; restore_adapter="$(phase12b_test_adapter_path PHASE12B_RESTORE_ADAPTER)"; fi
add_script="$(phase12b_test_adapter_path PHASE12B_ADD_CALLER_SCRIPT)"; workflow_apply="$(phase12b_test_adapter_path PHASE12B_WORKFLOW_APPLY)"; verify_apply="$(phase12b_test_adapter_path PHASE12B_VERIFY)"
"$add_script" --project-id "$project_id" --repository-id "$repo_id" --secret-id "$secret" --pool-id "$pool"
secret_ready="$($gcloud_bin secrets describe "$secret" --project="$project_id" --format='value(name)' 2>/dev/null)" || { echo 'Unable to read Secret identity after preparation.' >&2; exit 3; }
[[ "$secret_ready" =~ /secrets/$secret$ ]] || { echo 'Secret creation/read-back postcondition failed.' >&2; exit 3; }
enabled_ready="$($gcloud_bin secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)' 2>/dev/null)" || { echo 'Unable to read enabled Secret version after preparation.' >&2; exit 3; }
[[ "$(phase12b_nonblank_line_count "$enabled_ready")" == 1 && "$enabled_ready" =~ /versions/[1-9][0-9]*$ ]] || { echo 'Onboarding requires exactly one enabled numeric Secret version before runner/workflow activation.' >&2; exit 3; }
iam_ready="$($gcloud_bin secrets get-iam-policy "$secret" --project="$project_id" --flatten='bindings[].members' --format='value(bindings.role,bindings.members)' 2>/dev/null)" || { echo 'Unable to read Secret IAM after preparation.' >&2; exit 3; }
phase12b_secret_iam_exact "$iam_ready" "$iam_member" || { echo 'Secret IAM exact role/member postcondition failed.' >&2; exit 3; }
[[ "$lifecycle" != RETIRED_MATCH ]] || "$restore_adapter" "$repo_id" "$secret" "$retired_version"
phase12b_caller_runner Onboard "$host_config" "$repo" "$repo_id"
"$workflow_apply" "$repo" "$repo_id" "$branch"
phase12b_caller_runner Verify "$host_config" "$repo" "$repo_id" >/dev/null
"$verify_apply" "$repo" "$repo_id" "$secret"
phase12b_audit ONBOARD_APPLY "$repo" apply; echo 'ONBOARD_APPLY=PASS'
