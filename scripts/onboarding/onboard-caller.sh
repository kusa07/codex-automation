#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/phase12b-config.sh"
usage() { echo "Usage: $0 --environment FILE --caller FILE [--template FILE --output FILE] [--mode plan|apply --approve]"; }
mode=plan; approval=''; environment=''; caller=''; template=''; output=''
while [[ $# -gt 0 ]]; do case "$1" in --environment) environment="${2:-}"; shift 2;; --caller) caller="${2:-}"; shift 2;; --template) template="${2:-}"; shift 2;; --output) output="${2:-}"; shift 2;; --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ -n "$environment" && -n "$caller" ]] || { usage >&2; exit 2; }
phase12b_plan_or_apply "$mode" "$approval"; phase12b_require_yaml_file "$environment"; phase12b_require_yaml_file "$caller"
phase12b_validate_environment "$environment"; phase12b_validate_caller "$caller"
repo="$(phase12b_yaml_value "$caller" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$caller" '.repository.id')"; secret="$(phase12b_yaml_value "$caller" '.secret.id')"; sha="$(phase12b_yaml_value "$environment" '.automation.active_workflow_sha')"
automation_repo="$(phase12b_yaml_value "$environment" '.automation.repository')"; workflow_path="$(phase12b_yaml_value "$environment" '.automation.workflow_path')"; project_id="$(phase12b_yaml_value "$environment" '.google_cloud.project_id')"; provider="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_provider_resource')"
phase12b_require_secret_id "$secret"; phase12b_require_sha "$sha"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$repo_id" =~ ^[1-9][0-9]*$ && "$automation_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$workflow_path" =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ && "$provider" =~ ^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$ ]] || { echo 'Caller or environment identity is incomplete.' >&2; exit 2; }
printf 'ONBOARD_PLAN=PASS\nREPOSITORY=%s\nREPOSITORY_ID=%s\nSECRET_ID=%s\nWORKFLOW_SHA=%s\nMODE=%s\n' "$repo" "$repo_id" "$secret" "$sha" "$mode"
if [[ -n "$template" || -n "$output" ]]; then
  echo 'Batch A onboarding does not write caller workflows; use the dedicated sync operation in a later approved batch.' >&2
  exit 3
fi
if [[ "$mode" != plan ]]; then echo 'ONBOARD_APPLY=NOT_IMPLEMENTED_BATCH_A' >&2; exit 3; fi
