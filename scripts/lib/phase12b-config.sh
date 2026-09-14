#!/usr/bin/env bash
set -euo pipefail

phase12b_require_yq() {
  command -v yq >/dev/null 2>&1 || { echo 'Required prerequisite not found: yq (mikefarah/yq v4).' >&2; return 127; }
  local version; version="$(yq --version 2>/dev/null || true)"
  [[ "$version" == *'version 4.'* ]] || { echo "Unsupported yq version: ${version:-unknown}; require yq v4." >&2; return 2; }
}
phase12b_require_yaml_file() {
  local file="$1"; [[ -f "$file" ]] || { echo "Configuration file not found: $file" >&2; return 2; }
  phase12b_require_yq; yq -e 'type == "!!map"' "$file" >/dev/null || { echo "Configuration root must be a YAML mapping: $file" >&2; return 2; }
}
phase12b_require_schema() {
  local file="$1" schema; schema="$(yq -r '.schema_version // ""' "$file")"
  [[ "$schema" == 1 ]] || { echo "Unsupported or missing schema_version in $file" >&2; return 2; }
}
phase12b_yaml_value() { local file="$1" query="$2"; phase12b_require_yaml_file "$file"; phase12b_require_schema "$file"; yq -r "${query} // \"\"" "$file"; }
phase12b_require_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected a 40-character lowercase commit SHA.' >&2; return 2; }; }
phase12b_require_secret_id() { [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_-]{0,254}$ ]] || { echo 'Invalid Secret ID.' >&2; return 2; }; }
phase12b_classify_caller_lifecycle() {
  local active_id="${1:-}" retired_id="${2:-}" requested_id="${3:-}"
  [[ "$requested_id" =~ ^[1-9][0-9]*$ ]] || { echo IDENTITY_CONFLICT; return; }
  if [[ -n "$active_id" && -n "$retired_id" ]]; then echo IDENTITY_CONFLICT
  elif [[ -n "$active_id" && "$active_id" == "$requested_id" ]]; then echo ACTIVE_MATCH
  elif [[ -n "$retired_id" && "$retired_id" == "$requested_id" ]]; then echo RETIRED_MATCH
  elif [[ -z "$active_id" && -z "$retired_id" ]]; then echo NEW
  else echo IDENTITY_CONFLICT; fi
}
phase12b_classify_reonboard() {
  local expected_repository_id="${1:-}" actual_repository_id="${2:-}" expected_secret_id="${3:-}" actual_secret_id="${4:-}" version_id="${5:-}" version_exists="${6:-}" version_state="${7:-}" auth_valid="${8:-}" enabled_count="${9:-}"
  [[ "$expected_repository_id" =~ ^[1-9][0-9]*$ && "$expected_repository_id" == "$actual_repository_id" ]] || { echo STOP; return; }
  phase12b_require_secret_id "$expected_secret_id" >/dev/null || { echo STOP; return; }
  [[ "$expected_secret_id" == "$actual_secret_id" && "$version_id" =~ ^[1-9][0-9]*$ && "$version_exists" == true && "$version_state" == DISABLED && "$auth_valid" == true && "$enabled_count" == 0 ]] && echo RESTORE_CANDIDATE || echo STOP
}
phase12b_validate_environment() {
  local file="$1" owner owner_id project project_number pool provider resource repository workflow sha
  owner="$(phase12b_yaml_value "$file" '.github.owner')"; owner_id="$(phase12b_yaml_value "$file" '.github.owner_id')"
  project="$(phase12b_yaml_value "$file" '.google_cloud.project_id')"; project_number="$(phase12b_yaml_value "$file" '.google_cloud.project_number')"
  pool="$(phase12b_yaml_value "$file" '.google_cloud.workload_identity_pool')"; provider="$(phase12b_yaml_value "$file" '.google_cloud.workload_identity_provider')"; resource="$(phase12b_yaml_value "$file" '.google_cloud.workload_identity_provider_resource')"
  repository="$(phase12b_yaml_value "$file" '.automation.repository')"; workflow="$(phase12b_yaml_value "$file" '.automation.workflow_path')"; sha="$(phase12b_yaml_value "$file" '.automation.active_workflow_sha')"
  [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ && "$owner_id" =~ ^[1-9][0-9]*$ && "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ && "$project_number" =~ ^[0-9]+$ && "$pool" =~ ^[a-z0-9-]+$ && "$provider" =~ ^[a-z0-9-]+$ && "$resource" == "projects/$project_number/locations/global/workloadIdentityPools/$pool/providers/$provider" && "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$workflow" =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] || { echo 'Environment configuration has missing or invalid required fields.' >&2; return 2; }
  phase12b_require_sha "$sha"
}
phase12b_validate_caller() {
  local file="$1" repo repo_id secret workflow enabled scope
  repo="$(phase12b_yaml_value "$file" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$file" '.repository.id')"; secret="$(phase12b_yaml_value "$file" '.secret.id')"; workflow="$(phase12b_yaml_value "$file" '.workflow.path')"; enabled="$(phase12b_yaml_value "$file" '.runner.enabled')"; scope="$(phase12b_yaml_value "$file" '.runner.scope')"
  [[ "$repo" =~ ^[^/]+/[^/]+$ && "$repo_id" =~ ^[1-9][0-9]*$ && "$workflow" == .github/workflows/*.yml && "$enabled" =~ ^(true|false)$ && "$scope" == repository ]] || { echo 'Caller configuration has missing or invalid required fields.' >&2; return 2; }
  phase12b_require_secret_id "$secret"
}
phase12b_validate_host() {
  local file="$1" host platform mode identity sid serialization labels
  host="$(phase12b_yaml_value "$file" '.host_id')"; platform="$(phase12b_yaml_value "$file" '.platform')"; mode="$(phase12b_yaml_value "$file" '.runner.mode')"; identity="$(phase12b_yaml_value "$file" '.runner.service_identity')"; sid="$(phase12b_yaml_value "$file" '.runner.service_sid')"; serialization="$(phase12b_yaml_value "$file" '.execution.serialization')"; labels="$(phase12b_yaml_value "$file" '.runner.labels | join(",")')"
  [[ "$host" =~ ^[A-Za-z0-9_.-]+$ && "$platform" == windows && "$mode" == windows-service && "$identity" == network-service && "$sid" == S-1-5-20 && "$serialization" == global-mutex && "$labels" == 'self-hosted,Windows,X64,codex-automation' ]] || { echo 'Host configuration has missing or invalid required fields.' >&2; return 2; }
}
phase12b_plan_or_apply() {
  case "${1:-plan}" in
    plan) return 0 ;;
    apply) if [[ "${2:-}" != --approve ]]; then echo 'Mutation requires --apply --approve.' >&2; return 2; fi ;;
    *) echo 'Mode must be plan or apply.' >&2; return 2 ;;
  esac
}
