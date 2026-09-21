#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/../lib/phase12b-config.sh"
usage() { echo "Usage: $0 --caller callers/NAME.yaml --environment FILE [--retired-caller CANONICAL_FILE] [--mode plan|apply --approve] [test only: --test-mode --fixture-root DIR]"; }
[[ -z "${PHASE12B_TEST_MODE:-}${PHASE12B_TEST_ROOT:-}${PHASE12B_INTERNAL_TEST_MODE:-}${PHASE12B_INTERNAL_TEST_ROOT:-}" ]] || { echo 'Environment-based test activation is prohibited.' >&2; exit 3; }
mode=plan; approval=''; caller=''; environment=''; retired_caller=''; test_mode=false; fixture_root=''
while [[ $# -gt 0 ]]; do case "$1" in
  --caller) caller="${2:-}"; shift 2;; --environment) environment="${2:-}"; shift 2;; --retired-caller) retired_caller="${2:-}"; shift 2;;
  --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; --test-mode) test_mode=true; shift;; --fixture-root) fixture_root="${2:-}"; shift 2;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ -n "$caller" && -n "$environment" ]] || { usage >&2; exit 2; }
$test_mode && phase12b_enable_test_mode "$fixture_root"
phase12b_plan_or_apply "$mode" "$approval" || exit $?
phase12b_require_yaml_file "$environment" || exit $?
phase12b_validate_environment "$environment" || exit $?
retired_caller="$(phase12b_canonical_retired_caller "$caller" "$retired_caller")" || exit $?
active_exists=false; retired_exists=false; caller_authority=''
[[ ! -L "$caller" ]] || { echo 'Active caller desired-state path is unsafe.' >&2; exit 3; }
if [[ -e "$caller" ]]; then
  phase12b_require_yaml_file "$caller" || exit $?; phase12b_validate_caller "$caller" || exit $?; active_exists=true; caller_authority="$caller"
elif [[ -f "$retired_caller" && ! -L "$retired_caller" ]]; then
  phase12b_validate_retired_caller "$retired_caller" || exit $?; caller_authority="$retired_caller"
else
  echo 'Caller desired state is unavailable from both active and canonical retired records.' >&2; exit 3
fi
if [[ -e "$retired_caller" ]]; then
  [[ -f "$retired_caller" && ! -L "$retired_caller" ]] || { echo 'Retired desired-state authority is unsafe.' >&2; exit 3; }
  phase12b_validate_retired_caller "$retired_caller" || exit $?; retired_exists=true
fi
if phase12b_test_mode; then
  phase12b_assert_test_file_path "$environment" environment
  if [[ "$active_exists" == true ]]; then phase12b_assert_test_file_path "$caller" caller; else phase12b_assert_test_output_path "$caller" caller; fi
  if [[ "$retired_exists" == true ]]; then phase12b_assert_test_file_path "$retired_caller" retired-caller; else phase12b_assert_test_output_path "$retired_caller" retired-caller; fi
fi
repo="$(phase12b_yaml_value "$caller_authority" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$caller_authority" '.repository.id')"; secret="$(phase12b_yaml_value "$caller_authority" '.secret.id')"; workflow_path="$(phase12b_yaml_value "$caller_authority" '.workflow.path')"; workflow_branch="$(phase12b_yaml_value "$caller_authority" '.workflow.branch')"; project_id="$(phase12b_yaml_value "$environment" '.google_cloud.project_id')"; project_number="$(phase12b_yaml_value "$environment" '.google_cloud.project_number')"; pool_id="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_pool')"
host_config=''; host_inspect=''; workflow_sha=''
if ! phase12b_test_mode; then
  phase12b_reject_production_test_injections PHASE12B_GCLOUD_BIN PHASE12B_SERVICE_STOP PHASE12B_RUNNER_UNREGISTER PHASE12B_WORKFLOW_REMOVE PHASE12B_VERIFY PHASE12B_SECRET_DISABLE PHASE12B_STATE_RETIRE PHASE12B_REMOVE_CALLER_SCRIPT || exit $?
fi
host_config="$(phase12b_resolve_host_config "$environment")"
host_inspect="$(phase12b_caller_runner Inspect "$host_config" "$repo" "$repo_id")" || { echo 'Canonical host Inspect failed.' >&2; exit 3; }
host_lifecycle="$(sed -n 's/^CALLER_RUNNER_LIFECYCLE_STATE_AFTER=//p' <<< "$host_inspect")"
[[ "$host_lifecycle" =~ ^(ACTIVE|RETIRING|DISPATCH_DISABLED|SERVICE_STOPPED|RUNNER_REMOVED|RETIRED)$ ]] || { echo 'Canonical host lifecycle is not offboard-resumable.' >&2; exit 3; }
if phase12b_test_mode; then gh_bin="$(phase12b_test_fixture_root)/bin/gh";[[ -x "$gh_bin" && ! -L "$gh_bin" ]] || { echo 'Fixed test gh fixture is missing or unsafe.' >&2; exit 3; };else gh_bin=gh;command -v "$gh_bin" >/dev/null 2>&1 || { echo 'gh is required for repository/workflow grounding.' >&2; exit 127; };fi
actual_repo_id="$($gh_bin repo view "$repo" --json databaseId --jq '.databaseId')" || { echo 'Repository ID read-back failed.' >&2; exit 3; }
actual_branch="$($gh_bin repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name')" || { echo 'Default branch read-back failed.' >&2; exit 3; }
[[ "$actual_repo_id" == "$repo_id" && "$actual_branch" == "$workflow_branch" ]] || { echo 'Repository identity/default branch contradicts desired state.' >&2; exit 3; }
workflow_state="$(phase12b_github_content_state "$gh_bin" "repos/$repo/contents/$workflow_path?ref=$workflow_branch")" || exit $?
case "$workflow_state" in
  PRESENT) workflow_sha="$($gh_bin api "repos/$repo/contents/$workflow_path?ref=$workflow_branch" --jq '.sha')";[[ "$workflow_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Caller workflow immutable blob SHA is invalid.' >&2; exit 3; };;
  ABSENT) workflow_sha=ABSENT;;
esac
if phase12b_test_mode; then gcloud_bin="$(phase12b_test_fixture_root)/bin/gcloud";[[ -x "$gcloud_bin" && ! -L "$gcloud_bin" ]] || { echo 'Fixed test gcloud fixture is missing or unsafe.' >&2; exit 3; };else gcloud_bin=gcloud;command -v "$gcloud_bin" >/dev/null 2>&1 || { echo 'gcloud is required for authoritative Secret metadata.' >&2; exit 127; };fi;phase12b_require_secret_id "$secret" || exit $?
iam_member="principalSet://iam.googleapis.com/projects/$project_number/locations/global/workloadIdentityPools/$pool_id/attribute.repository_id/$repo_id"
iam_before="$($gcloud_bin secrets get-iam-policy "$secret" --project="$project_id" --flatten='bindings[].members[]' --format='value(bindings.role,bindings.members)' 2>/dev/null)" || { echo 'Unable to read caller IAM state.' >&2; exit 3; }
iam_cleanup_required=false
if awk -F '\t' -v member="$iam_member" '$2 == member { found=1 } END { exit !found }' <<< "$iam_before"; then iam_cleanup_required=true; fi

# Metadata-only queries: payload access is never performed.  An unavailable
# control plane is not equivalent to an empty enabled-version set.
if ! enabled_resources="$("$gcloud_bin" secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)' 2>/dev/null)"; then
  echo 'Unable to read enabled Secret version metadata.' >&2; exit 3
fi
enabled_count="$(phase12b_nonblank_line_count "$enabled_resources")"; authoritative_version=''
enabled_lines=(); while IFS= read -r enabled_line; do [[ -z "${enabled_line//[[:space:]]/}" ]] || enabled_lines+=("$enabled_line"); done <<< "$enabled_resources"
if [[ "$enabled_count" == 1 && "${enabled_lines[0]}" =~ /versions/([1-9][0-9]*)$ ]]; then authoritative_version="${BASH_REMATCH[1]}"; fi
retirement_state=NEW
if [[ "$retired_exists" == true ]]; then
  retired_repo="$(phase12b_yaml_value "$retired_caller" '.repository.full_name')"; retired_repo_id="$(phase12b_yaml_value "$retired_caller" '.repository.id')"; retired_secret="$(phase12b_yaml_value "$retired_caller" '.secret.id')"; retired_workflow_path="$(phase12b_yaml_value "$retired_caller" '.workflow.path')"; retired_workflow_branch="$(phase12b_yaml_value "$retired_caller" '.workflow.branch')"; retired_version="$(phase12b_yaml_value "$retired_caller" '.lifecycle.last_authoritative_secret_version')"; retirement_state="$(phase12b_yaml_value "$retired_caller" '.lifecycle.state')"
  [[ "$retired_repo" == "$repo" && "$retired_repo_id" == "$repo_id" && "$retired_secret" == "$secret" && "$retired_workflow_path" == "$workflow_path" && "$retired_workflow_branch" == "$workflow_branch" ]] || { echo 'Retired desired-state authority conflicts with caller identity.' >&2; exit 3; }
  authoritative_version="$retired_version"
fi
if ! metadata="$("$gcloud_bin" secrets versions list "$secret" --project="$project_id" --format='json(name,state)' 2>/dev/null)"; then
  echo 'Unable to read complete Secret version metadata.' >&2; exit 3
fi
printf 'OFFBOARD_PLAN=PASS\nREPOSITORY=%s\nREPOSITORY_ID=%s\nSECRET_ID=%s\nENABLED_VERSION_COUNT=%s\nAUTHORITATIVE_VERSION_ID=%s\nSECRET_VERSION_METADATA=%s\nDESIRED_STATE_TRANSITION=ACTIVE_TO_RETIRED\nMODE=%s\n' "$repo" "$repo_id" "$secret" "$enabled_count" "${authoritative_version:-UNKNOWN}" "$metadata" "$mode"
phase12b_audit OFFBOARD_PLAN "$repo" "$mode"
if [[ "$enabled_count" == 1 ]]; then
  [[ -n "$authoritative_version" && "${enabled_lines[0]}" =~ /versions/$authoritative_version$ ]] || { echo 'Enabled Secret version contradicts retirement authority.' >&2; exit 3; }
elif [[ "$enabled_count" == 0 && "$retirement_state" =~ ^(retiring|retired)$ ]]; then
  disabled_resume_state="$($gcloud_bin secrets versions describe "$authoritative_version" --secret="$secret" --project="$project_id" --format='value(state)' 2>/dev/null)" || { echo 'Unable to read authoritative Secret version for resume.' >&2; exit 3; }
  [[ "$disabled_resume_state" == DISABLED ]] || { echo 'Zero enabled versions are safe only when the fixed authoritative version is DISABLED.' >&2; exit 3; }
else
  echo 'Offboard requires one enabled authoritative version or an exact disabled-version resume authority.' >&2; exit 3
fi

# Once the active desired-state entry has been retired, only the canonical
# retired record may authorize either the final local metadata transition or a
# completed read-only verification.  No external mutation is replayed.
if [[ "$retired_exists" == true && "$retirement_state" == retired && "$host_lifecycle" =~ ^(RUNNER_REMOVED|RETIRED)$ ]]; then
  if [[ "$active_exists" == true && "$host_lifecycle" == RETIRED ]]; then echo 'Active and retired desired state coexist after lifecycle completion.' >&2; exit 3; fi
  [[ "$workflow_state" == ABSENT ]] || { echo 'Retired caller workflow is still dispatchable.' >&2; exit 3; }
  [[ "$enabled_count" == 0 ]] || { echo 'Retired caller unexpectedly has an enabled Secret version.' >&2; exit 3; }
  exact_version_metadata="$($gcloud_bin secrets versions describe "$authoritative_version" --secret="$secret" --project="$project_id" --format='value(name,state)' 2>/dev/null)" || { echo 'Unable to read exact retired Secret version metadata.' >&2; exit 3; }
  IFS=$'\t' read -r exact_version_resource exact_version_state <<< "$exact_version_metadata"
  [[ "$exact_version_resource" =~ /secrets/$secret/versions/$authoritative_version$ && "$exact_version_state" == DISABLED ]] || { echo 'Retired Secret authority does not match the exact disabled version.' >&2; exit 3; }
  retired_iam="$($gcloud_bin secrets get-iam-policy "$secret" --project="$project_id" --flatten='bindings[].members[]' --format='value(bindings.role,bindings.members)' 2>/dev/null)" || { echo 'Unable to read retired caller IAM postcondition.' >&2; exit 3; }
  if awk -F '\t' -v member="$iam_member" '$2 == member { found=1 } END { exit !found }' <<< "$retired_iam"; then echo 'Retired caller IAM binding remains present.' >&2; exit 3; fi
  if [[ "$mode" != apply ]]; then
    if [[ "$host_lifecycle" == RETIRED ]]; then
      printf 'POSTCONDITION=RETIRED_VERIFY_READY\nMUTATIONS_PERFORMED=NONE\nNEXT_ACTION=NONE\n'
    else
      printf 'POSTCONDITION=RETIRED_FINALIZATION_READY\nMUTATIONS_PERFORMED=NONE\nNEXT_ACTION=FINALIZE_RETIRED_STATE\n'
    fi
    exit 0
  fi
  mutation_result=NONE
  if [[ "$active_exists" == true ]]; then
    rm -- "$caller"
    [[ ! -e "$caller" ]] || { echo 'Active caller desired state remains after retirement.' >&2; exit 3; }
    mutation_result=ACTIVE_DESIRED_STATE_RETIREMENT
  fi
  if [[ "$host_lifecycle" == RUNNER_REMOVED ]]; then
    phase12b_caller_runner Offboard "$host_config" "$repo" "$repo_id" finalize >/dev/null
    if [[ "$mutation_result" == NONE ]]; then mutation_result=LOCAL_METADATA_FINALIZATION; else mutation_result=ACTIVE_DESIRED_STATE_RETIREMENT_AND_LOCAL_METADATA_FINALIZATION; fi
  fi
  retired_verify="$(phase12b_caller_runner Verify "$host_config" "$repo" "$repo_id")" || { echo 'Canonical RETIRED verification failed.' >&2; exit 3; }
  grep -q '^CALLER_RUNNER_LIFECYCLE_STATE_AFTER=RETIRED$' <<< "$retired_verify" || { echo 'Canonical lifecycle is not RETIRED after verification.' >&2; exit 3; }
  [[ ! -e "$caller" && -f "$retired_caller" && ! -L "$retired_caller" ]] || { echo 'Caller desired-state retirement postcondition failed.' >&2; exit 3; }
  phase12b_audit OFFBOARD_APPLY "$repo" apply
  printf 'OFFBOARD_APPLY=PASS\nRESULT=PASS\nPOSTCONDITION=RETIRED_VERIFIED\nMUTATIONS_PERFORMED=%s\nNEXT_ACTION=NONE\n' "$mutation_result"
  exit 0
fi
if [[ "$active_exists" == false ]]; then
  echo 'Active caller is absent before an exact retired finalization state was established.' >&2; exit 3
fi

[[ "$mode" == plan ]] && exit 0
[[ "${PHASE12B_APPROVAL_TOKEN:-}" == approve-offboard || "$approval" == --approve ]] || { echo 'Approval token missing.' >&2; exit 2; }
if [[ ! -e "$retired_caller" ]]; then
  phase12b_test_mode && phase12b_assert_test_output_path "$retired_caller" retired-caller
  mkdir -p -- "$(dirname -- "$retired_caller")"
  tmp_intent="${retired_caller}.tmp.$$"; umask 077
  cat > "$tmp_intent" <<EOF
schema_version: 1
repository:
  full_name: $repo
  id: $repo_id
secret:
  id: $secret
workflow:
  path: $workflow_path
  branch: $workflow_branch
lifecycle:
  state: retiring
  last_authoritative_secret_version: $authoritative_version
EOF
  mv -- "$tmp_intent" "$retired_caller"; retirement_state=retiring
fi

# Re-read immediately before mutation. The planned version is the only version
# eligible for disable; concurrent lifecycle change is fail-closed.
if ! enabled_resources_now="$("$gcloud_bin" secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)' 2>/dev/null)"; then
  echo 'Unable to re-read enabled Secret version metadata before offboard.' >&2; exit 3
fi
enabled_now=(); while IFS= read -r enabled_line; do [[ -z "${enabled_line//[[:space:]]/}" ]] || enabled_now+=("$enabled_line"); done <<< "$enabled_resources_now"
if [[ "${#enabled_now[@]}" == 1 ]]; then [[ "${enabled_now[0]}" =~ /versions/$authoritative_version$ ]] || { echo 'Secret enabled-version state changed since plan.' >&2; exit 3; }; disable_required=true
elif [[ "${#enabled_now[@]}" == 0 ]]; then exact_state="$($gcloud_bin secrets versions describe "$authoritative_version" --secret="$secret" --project="$project_id" --format='value(state)' 2>/dev/null)" || { echo 'Unable to verify disabled resume state.' >&2; exit 3; };[[ "$exact_state" == DISABLED ]] || { echo 'Disabled resume authority is not exact.' >&2; exit 3; };disable_required=false
else echo 'Secret enabled-version state changed since plan.' >&2; exit 3; fi
if [[ "$host_lifecycle" == ACTIVE ]]; then
  phase12b_caller_runner Offboard "$host_config" "$repo" "$repo_id" begin
  host_lifecycle=RETIRING
fi
if [[ "$host_lifecycle" == RETIRING ]]; then
  if [[ "$workflow_sha" != ABSENT ]]; then
    if phase12b_test_mode; then workflow_remove="$(phase12b_test_adapter_path PHASE12B_WORKFLOW_REMOVE)";"$workflow_remove" "$repo" "$repo_id" "$workflow_path" "$workflow_branch"
    else "$gh_bin" api --method DELETE "repos/$repo/contents/$workflow_path" -f message='Retire caller workflow' -f branch="$workflow_branch" -f sha="$workflow_sha" >/dev/null
    fi
  fi
  workflow_after="$(phase12b_github_content_state "$gh_bin" "repos/$repo/contents/$workflow_path?ref=$workflow_branch")" || exit $?
  [[ "$workflow_after" == ABSENT ]] || { echo 'Caller workflow remains after retirement.' >&2; exit 1; }
fi
if [[ "$host_lifecycle" =~ ^(DISPATCH_DISABLED|SERVICE_STOPPED|RUNNER_REMOVED|RETIRED)$ && "$workflow_state" != ABSENT ]]; then
  echo 'Downstream host lifecycle contradicts workflow retirement read-back.' >&2; exit 3
fi
if [[ "$host_lifecycle" =~ ^(RETIRING|DISPATCH_DISABLED|SERVICE_STOPPED)$ ]]; then
  phase12b_caller_runner Offboard "$host_config" "$repo" "$repo_id"
  host_lifecycle=RUNNER_REMOVED
fi
if phase12b_test_mode; then
  verify_apply="$(phase12b_test_adapter_path PHASE12B_VERIFY)"
  remove_script="$(phase12b_test_adapter_path PHASE12B_REMOVE_CALLER_SCRIPT)"
fi
if [[ "$disable_required" == true && -n "${PHASE12B_SECRET_DISABLE:-}" ]]; then
  secret_disable="$(phase12b_test_adapter_path PHASE12B_SECRET_DISABLE)"
  "$secret_disable" "$secret" "$authoritative_version"
elif [[ "$disable_required" == true ]]; then
  "$gcloud_bin" secrets versions disable "$authoritative_version" --secret="$secret" --project="$project_id" --quiet >/dev/null
fi
if ! enabled_after="$("$gcloud_bin" secrets versions list "$secret" --project="$project_id" --filter='state=ENABLED' --format='value(name)' 2>/dev/null)"; then
  echo 'Unable to read Secret metadata after disable.' >&2; exit 3
fi
enabled_after_count="$(phase12b_nonblank_line_count "$enabled_after")"
[[ "$enabled_after_count" == 0 ]] || { echo 'Post-offboard Secret metadata did not reach zero enabled versions.' >&2; exit 1; }
if ! disabled_state="$("$gcloud_bin" secrets versions describe "$authoritative_version" --secret="$secret" --project="$project_id" --format='value(state)' 2>/dev/null)"; then
  echo 'Unable to read disabled authoritative Secret version metadata.' >&2; exit 3
fi
[[ "$disabled_state" == DISABLED ]] || { echo 'Exact authoritative Secret version was not disabled.' >&2; exit 1; }
if [[ "$iam_cleanup_required" == true ]]; then
  if phase12b_test_mode; then
    PHASE12B_APPROVAL_TOKEN=approve-offboard "$remove_script" --project-id "$project_id" --repository-id "$repo_id" --secret-id "$secret" --mode apply --approve
  else
    PHASE12B_APPROVAL_TOKEN=approve-offboard "$SCRIPT_DIR/../google-cloud/remove-caller.sh" --environment "$environment" --caller "$caller" --mode apply --approve
  fi
fi
iam_after="$($gcloud_bin secrets get-iam-policy "$secret" --project="$project_id" --flatten='bindings[].members[]' --format='value(bindings.role,bindings.members)' 2>/dev/null)" || { echo 'Unable to verify caller IAM retirement.' >&2; exit 3; }
if awk -F '\t' -v member="$iam_member" '$2 == member { found=1 } END { exit !found }' <<< "$iam_after"; then echo 'Target caller IAM binding remains after retirement.' >&2; exit 1; fi

# Retired desired-state metadata is re-onboarding authority, never input.
tmp_record="${retired_caller}.tmp.$$"
umask 077
cat > "$tmp_record" <<EOF
schema_version: 1
repository:
  full_name: $repo
  id: $repo_id
secret:
  id: $secret
workflow:
  path: $workflow_path
  branch: $workflow_branch
lifecycle:
  state: retired
  last_authoritative_secret_version: $authoritative_version
EOF
mv -- "$tmp_record" "$retired_caller"
[[ -f "$retired_caller" && ! -L "$retired_caller" ]] || { echo 'Retired desired-state write failed.' >&2; exit 1; }
if phase12b_test_mode && [[ -n "${PHASE12B_STATE_RETIRE:-}" ]]; then state_retire="$(phase12b_test_adapter_path PHASE12B_STATE_RETIRE)"; "$state_retire" "$retired_caller" "$repo_id" "$secret" "$authoritative_version"; fi
[[ -f "$caller" && ! -L "$caller" ]] || { echo 'Active caller retirement target is unsafe.' >&2; exit 3; }
rm -- "$caller"
[[ ! -e "$caller" ]] || { echo 'Active caller desired state remains authoritative after retirement.' >&2; exit 1; }
if [[ "$host_lifecycle" != RETIRED ]]; then
  phase12b_caller_runner Offboard "$host_config" "$repo" "$repo_id" finalize
  host_lifecycle=RETIRED
fi
final_host="$(phase12b_caller_runner Inspect "$host_config" "$repo" "$repo_id")" || { echo 'Final canonical host read-back failed.' >&2; exit 3; }
grep -q '^CALLER_RUNNER_LIFECYCLE_STATE_AFTER=RETIRED$' <<< "$final_host" || { echo 'Final host lifecycle is not RETIRED.' >&2; exit 1; }
if phase12b_test_mode; then
  "$verify_apply" "$repo" "$repo_id" "$secret" "$authoritative_version"
fi
phase12b_audit OFFBOARD_APPLY "$repo" apply
echo 'OFFBOARD_APPLY=PASS'
