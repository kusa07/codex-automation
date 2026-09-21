#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/../lib/phase12b-config.sh"
usage() { echo "Usage: $0 --environment FILE --caller FILE [--mode plan|apply --approve] [test only: --test-mode --fixture-root DIR]"; }
[[ -z "${PHASE12B_TEST_MODE:-}${PHASE12B_TEST_ROOT:-}${PHASE12B_INTERNAL_TEST_MODE:-}${PHASE12B_INTERNAL_TEST_ROOT:-}" ]] || { echo 'Environment-based test activation is prohibited.' >&2; exit 3; }
environment=''; caller=''; mode=plan; approval=''; test_mode=false; fixture_root=''
while [[ $# -gt 0 ]]; do case "$1" in
  --environment) environment="${2:-}"; shift 2;; --caller) caller="${2:-}"; shift 2;;
  --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; --test-mode) test_mode=true; shift;; --fixture-root) fixture_root="${2:-}"; shift 2;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ -n "$environment" && -n "$caller" ]] || { usage >&2; exit 2; }
$test_mode && phase12b_enable_test_mode "$fixture_root"
if phase12b_test_mode; then phase12b_assert_test_file_path "$environment" environment;phase12b_assert_test_file_path "$caller" caller;fi
phase12b_plan_or_apply "$mode" "$approval"; phase12b_require_yaml_file "$environment"; phase12b_validate_environment "$environment"; phase12b_require_yaml_file "$caller"; phase12b_validate_caller "$caller"
if ! phase12b_test_mode; then phase12b_reject_production_test_injections PHASE12B_GCLOUD_BIN PHASE12B_IAM_REVOKE POOL_ID PHASE12B_IAM_POLICY PHASE12B_PROJECT_NUMBER || exit $?; fi
project_id="$(phase12b_yaml_value "$environment" '.google_cloud.project_id')"; project_number="$(phase12b_yaml_value "$environment" '.google_cloud.project_number')"; pool_id="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_pool')"; provider_id="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_provider')"
repository_id="$(phase12b_yaml_value "$caller" '.repository.id')"; secret="$(phase12b_yaml_value "$caller" '.secret.id')"
if phase12b_test_mode; then gcloud_bin="$(phase12b_test_fixture_root)/bin/gcloud"; [[ -x "$gcloud_bin" && -f "$gcloud_bin" && ! -L "$gcloud_bin" ]] || { echo 'Fixed test gcloud fixture is missing or unsafe.' >&2; exit 3; }; else gcloud_bin=gcloud; command -v "$gcloud_bin" >/dev/null 2>&1 || { echo 'gcloud required for IAM cleanup.' >&2; exit 127; }; fi
actual_project_number="$($gcloud_bin projects describe "$project_id" --format='value(projectNumber)' 2>/dev/null)" || { echo 'Project authority read-back failed.' >&2; exit 3; }
[[ "$actual_project_number" == "$project_number" ]] || { echo 'Project number contradicts environment desired state.' >&2; exit 3; }
provider_name="$($gcloud_bin iam workload-identity-pools providers describe "$provider_id" --project="$project_id" --location=global --workload-identity-pool="$pool_id" --format='value(name)' 2>/dev/null)" || { echo 'WIF Provider authority read-back failed.' >&2; exit 3; }
[[ "$provider_name" == "projects/$project_number/locations/global/workloadIdentityPools/$pool_id/providers/$provider_id" ]] || { echo 'WIF Provider contradicts environment desired state.' >&2; exit 3; }
member="principalSet://iam.googleapis.com/projects/$project_number/locations/global/workloadIdentityPools/$pool_id/attribute.repository_id/$repository_id"
read_policy() { "$gcloud_bin" secrets get-iam-policy "$secret" --project="$project_id" --flatten='bindings[].members[]' --format='value(bindings.role,bindings.members)' 2>/dev/null; }
if ! before_policy="$(read_policy)"; then echo 'Secret IAM policy read-back failed before cleanup.' >&2; exit 3; fi
before_unrelated="$(awk -F '\t' -v member="$member" '$2 != member { print }' <<< "$before_policy" | sort)"
printf 'OFFBOARD_PLAN=PASS\nPROJECT_ID=%s\nPOOL_ID=%s\nPROVIDER_ID=%s\nREPOSITORY_ID=%s\nSECRET_ID=%s\nMODE=%s\n' "$project_id" "$pool_id" "$provider_id" "$repository_id" "$secret" "$mode"
[[ "$mode" == plan ]] && exit 0
for role in roles/secretmanager.secretAccessor roles/secretmanager.secretVersionManager; do
  "$gcloud_bin" secrets remove-iam-policy-binding "$secret" --project="$project_id" --member="$member" --role="$role" --quiet >/dev/null
done
if ! after_policy="$(read_policy)"; then echo 'Secret IAM policy read-back failed after cleanup.' >&2; exit 3; fi
if awk -F '\t' -v member="$member" '$2 == member { found=1 } END { exit !found }' <<< "$after_policy"; then echo 'Target repository-ID IAM principal remains after cleanup.' >&2; exit 1; fi
after_unrelated="$(awk -F '\t' -v member="$member" '$2 != member { print }' <<< "$after_policy" | sort)"
[[ "$after_unrelated" == "$before_unrelated" ]] || { echo 'IAM cleanup changed unrelated bindings.' >&2; exit 1; }
echo 'REMOVE_CALLER_IAM=PASS'
