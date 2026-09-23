#!/usr/bin/env bash
set -euo pipefail

phase12b_is_yq_v4_version() {
  local version="${1:-}"
  [[ "$version" =~ ^((yq|yq[[:space:]]+\(https://github\.com/mikefarah/yq/\))[[:space:]]+)?version[[:space:]]+v?4\.[0-9]+\.[0-9]+$ ]]
}
phase12b_require_yq() {
  command -v yq >/dev/null 2>&1 || { echo 'Required prerequisite not found: yq (mikefarah/yq v4).' >&2; return 127; }
  local version; version="$(yq --version 2>/dev/null || true)"
  phase12b_is_yq_v4_version "$version" || { echo "Unsupported yq version: ${version:-unknown}; require yq v4." >&2; return 2; }
}
phase12b_require_yaml_file() {
  local file="$1"; [[ -f "$file" ]] || { echo "Configuration file not found: $file" >&2; return 2; }
  phase12b_require_yq; yq -e 'type == "!!map"' "$file" >/dev/null || { echo "Configuration root must be a YAML mapping: $file" >&2; return 2; }
}
phase12b_require_schema() {
  local file="$1" schema; schema="$(yq -r '.schema_version // ""' "$file")"
  [[ "$schema" == 1 ]] || { echo "Unsupported or missing schema_version in $file" >&2; return 2; }
}
phase12b_yaml_value() { local file="$1" query="$2"; phase12b_require_yaml_file "$file" || return; phase12b_require_schema "$file" || return; yq -r "${query} // \"\"" "$file"; }
phase12b_require_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected a 40-character lowercase commit SHA.' >&2; return 2; }; }
phase12b_require_secret_id() { [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_-]{0,254}$ ]] || { echo 'Invalid Secret ID.' >&2; return 2; }; }
phase12b_require_numeric_version() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Expected a numeric Secret version ID.' >&2; return 2; }; }
phase12b_require_branch() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$ && "$1" != *'..'* && "$1" != /* && "$1" != *'//' ]] || { echo 'Invalid branch name.' >&2; return 2; }; }
phase12b_nonblank_line_count() {
  local value="${1:-}" line count=0
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] || ((count+=1))
  done <<< "$value"
  printf '%s\n' "$count"
}
phase12b_secret_iam_exact() {
  local rows="${1:-}" expected_member="$2" role line total exact
  for role in roles/secretmanager.secretAccessor roles/secretmanager.secretVersionManager; do
    total=0;exact=0
    while IFS= read -r line; do
      [[ "$line" != "$role"$'\t'* ]] || ((total+=1))
      [[ "$line" != "$role"$'\t'"$expected_member" ]] || ((exact+=1))
    done <<< "$rows"
    [[ "$total" == 1 && "$exact" == 1 ]] || return 1
  done
}
phase12b_github_content_state() {
  local gh_bin="$1" endpoint="$2" response status rc=0
  response="$($gh_bin api --include --silent "$endpoint" 2>&1)" || rc=$?
  status="$(sed -n '1{s/\r$//;s/.* \([0-9][0-9][0-9]\) .*/\1/p;}' <<< "$response")"
  case "$status:$rc" in
    200:0) printf 'PRESENT\n' ;;
    404:*) printf 'ABSENT\n' ;;
    *) echo 'GitHub content read-back failed; only an explicit 404 proves absence.' >&2; return 3 ;;
  esac
}
phase12b_github_repository_metadata() {
  local gh_bin="$1" repository="$2" response repository_id full_name default_branch extra
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid repository identity.' >&2; return 3; }
  response="$("$gh_bin" api "repos/$repository" --jq '[.id, .full_name, .default_branch] | @tsv' 2>/dev/null)" || { echo 'GitHub repository metadata read-back failed.' >&2; return 3; }
  [[ "$response" != *$'\n'* && -n "$response" ]] || { echo 'GitHub repository metadata response is malformed.' >&2; return 3; }
  IFS=$'\t' read -r repository_id full_name default_branch extra <<< "$response"
  [[ -z "${extra:-}" && "$repository_id" =~ ^[1-9][0-9]*$ && "$full_name" == "$repository" ]] || { echo 'GitHub repository identity metadata is invalid or mismatched.' >&2; return 3; }
  phase12b_require_branch "$default_branch" || { echo 'GitHub repository default branch metadata is invalid.' >&2; return 3; }
  printf '%s\t%s\t%s\n' "$repository_id" "$full_name" "$default_branch"
}
phase12b_parse_wif_workflow_condition() {
  local condition="${1:-}" expected_owner_id="${2:-}" expected_repository="${3:-}" expected_workflow_path="${4:-}"
  local condition_re actual_owner actual_identity sha_list token sha
  local -a tokens=()
  local -A seen=()
  [[ "$expected_owner_id" =~ ^[1-9][0-9]*$ && "$expected_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$expected_workflow_path" =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] || return 3
  condition_re="^assertion\\.repository_owner_id[[:space:]]*==[[:space:]]*'([0-9]+)'[[:space:]]*&&[[:space:]]*assertion\\.job_workflow_ref\\.startsWith\\('([^']+@)'\\)[[:space:]]*&&[[:space:]]*assertion\\.job_workflow_sha[[:space:]]+in[[:space:]]+\\[(.*)\\]$"
  [[ "$condition" =~ $condition_re ]] || return 3
  actual_owner="${BASH_REMATCH[1]}"
  actual_identity="${BASH_REMATCH[2]}"
  sha_list="${BASH_REMATCH[3]}"
  [[ "$actual_owner" == "$expected_owner_id" && "$actual_identity" == "$expected_repository/$expected_workflow_path@" ]] || return 3
  [[ -n "$sha_list" ]] || return 3
  IFS=',' read -r -a tokens <<< "$sha_list"
  ((${#tokens[@]} > 0)) || return 3
  for token in "${tokens[@]}"; do
    token="${token#${token%%[![:space:]]*}}"; token="${token%${token##*[![:space:]]}}"
    [[ "${#token}" == 42 && "${token:0:1}" == "'" && "${token: -1}" == "'" ]] || return 3
    sha="${token:1:40}"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 3
    [[ -z "${seen[$sha]+x}" ]] || return 3
    seen["$sha"]=1
    printf '%s\n' "$sha"
  done
}
phase12b_enable_test_mode() {
  local root="$1"
  [[ -n "$root" && -d "$root" && ! -L "$root" ]] || { echo 'Test fixture root must be an existing non-symlink directory.' >&2; return 3; }
  root="$(cd -- "$root" && pwd -P)" || return 3
  [[ "$root" == /tmp/* || "$root" == /var/tmp/* ]] || { echo 'Test fixture root must be beneath a system temporary directory.' >&2; return 3; }
  PHASE12B_INTERNAL_TEST_MODE=1 PHASE12B_INTERNAL_TEST_ROOT="$root"
}
phase12b_test_mode() { [[ "${PHASE12B_INTERNAL_TEST_MODE:-}" == 1 ]]; }
phase12b_reject_production_test_injections() {
  local name
  for name in "$@"; do
    [[ -z "${!name:-}" ]] || { echo "Test-only injection is prohibited outside explicit --test-mode: $name" >&2; return 3; }
  done
}
phase12b_test_fixture_root() {
  phase12b_test_mode || { echo 'Test fixture adapter requires explicit --test-mode.' >&2; return 3; }
  local root="${PHASE12B_INTERNAL_TEST_ROOT:-}"
  [[ -n "$root" && -d "$root" && ! -L "$root" ]] || { echo 'Test fixture root must be an existing non-symlink directory.' >&2; return 3; }
  [[ "$root" == /tmp/* || "$root" == /var/tmp/* ]] || { echo 'Test fixture root must be beneath a system temporary directory.' >&2; return 3; }
  printf '%s\n' "$root"
}
phase12b_test_adapter_path() {
  local name="$1" path root resolved
  path="${!name:-}"; [[ -n "$path" ]] || { echo "Missing test adapter: $name" >&2; return 3; }
  root="$(phase12b_test_fixture_root)" || return
  [[ -f "$path" && -x "$path" && ! -L "$path" ]] || { echo "Test adapter is not an executable regular file: $name" >&2; return 3; }
  resolved="$(cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")"
  [[ "$resolved" == "$root"/* ]] || { echo "Test adapter escapes the fixture root: $name" >&2; return 3; }
  printf '%s\n' "$resolved"
}
phase12b_test_file_path() {
  local name="$1" path root resolved
  path="${!name:-}"; [[ -n "$path" ]] || { echo "Missing test fixture file: $name" >&2; return 3; }
  root="$(phase12b_test_fixture_root)" || return
  [[ -f "$path" && ! -L "$path" ]] || { echo "Test fixture file is unsafe or escapes FixtureRoot: $name" >&2; return 3; }
  resolved="$(cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")"
  [[ "$resolved" == "$root"/* ]] || { echo "Test fixture file is unsafe or escapes FixtureRoot: $name" >&2; return 3; }
  printf '%s\n' "$resolved"
}
phase12b_assert_test_file_path() {
  local path="$1" label="${2:-fixture}" root resolved
  root="$(phase12b_test_fixture_root)" || return
  [[ -f "$path" && ! -L "$path" ]] || { echo "Test $label file is unsafe or escapes FixtureRoot." >&2; return 3; }
  resolved="$(cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")"
  [[ "$resolved" == "$root"/* ]] || { echo "Test $label file is unsafe or escapes FixtureRoot." >&2; return 3; }
}
phase12b_assert_test_output_path() {
  local path="$1" label="${2:-output}" root parent resolved
  root="$(phase12b_test_fixture_root)" || return
  parent="$(dirname -- "$path")";[[ -d "$parent" && ! -L "$parent" ]] || { echo "Test $label parent is missing or unsafe." >&2; return 3; }
  resolved="$(cd -- "$parent" && pwd -P)/$(basename -- "$path")"
  [[ "$resolved" == "$root"/* ]] || { echo "Test $label path escapes FixtureRoot." >&2; return 3; }
}
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
  local file="$1" repo repo_id secret workflow branch enabled scope
  phase12b_require_yaml_file "$file" || return; phase12b_require_schema "$file" || return
  repo="$(phase12b_yaml_value "$file" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$file" '.repository.id')"; secret="$(phase12b_yaml_value "$file" '.secret.id')"; workflow="$(phase12b_yaml_value "$file" '.workflow.path')"; branch="$(phase12b_yaml_value "$file" '.workflow.branch')"; enabled="$(phase12b_yaml_value "$file" '.runner.enabled')"; scope="$(phase12b_yaml_value "$file" '.runner.scope')"
  [[ "$repo" =~ ^[^/]+/[^/]+$ && "$repo_id" =~ ^[1-9][0-9]*$ && "$workflow" == .github/workflows/*.yml && "$enabled" =~ ^(true|false)$ && "$scope" == repository ]] || { echo 'Caller configuration has missing or invalid required fields.' >&2; return 2; }
  phase12b_require_secret_id "$secret"
  phase12b_require_branch "$branch"
}
phase12b_validate_retired_caller() {
  local file="$1" repo repo_id secret workflow branch state version
  phase12b_require_yaml_file "$file" || return; phase12b_require_schema "$file" || return
  repo="$(phase12b_yaml_value "$file" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$file" '.repository.id')"; secret="$(phase12b_yaml_value "$file" '.secret.id')"; workflow="$(phase12b_yaml_value "$file" '.workflow.path')"; branch="$(phase12b_yaml_value "$file" '.workflow.branch')"; state="$(phase12b_yaml_value "$file" '.lifecycle.state')"; version="$(phase12b_yaml_value "$file" '.lifecycle.last_authoritative_secret_version')"
  [[ "$repo" =~ ^[^/]+/[^/]+$ && "$repo_id" =~ ^[1-9][0-9]*$ && "$workflow" == .github/workflows/*.yml && "$state" =~ ^(retiring|retired)$ ]] || { echo 'Retired caller configuration has missing or invalid required fields.' >&2; return 2; }
  phase12b_require_secret_id "$secret"; phase12b_require_branch "$branch"; phase12b_require_numeric_version "$version"
}
phase12b_canonical_retired_caller() {
  local caller="$1" supplied="${2:-}" caller_parent config_root basename retired_parent candidate supplied_parent supplied_resolved
  caller_parent="$(dirname -- "$caller")"; basename="$(basename -- "$caller")"
  [[ "$basename" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.yaml$ && "$basename" != *..* && -d "$caller_parent" && ! -L "$caller_parent" ]] || { echo 'Caller desired-state path is not a safe canonical callers entry.' >&2; return 3; }
  caller_parent="$(cd -- "$caller_parent" && pwd -P)" || return 3
  [[ "$(basename -- "$caller_parent")" == callers ]] || { echo 'Caller desired-state must be beneath the canonical callers directory.' >&2; return 3; }
  config_root="$(cd -- "$caller_parent/.." && pwd -P)" || return 3
  [[ "$caller_parent" == "$config_root/callers" ]] || { echo 'Caller desired-state path is not canonical.' >&2; return 3; }
  retired_parent="$config_root/retired-callers"
  if [[ -e "$retired_parent" ]]; then
    [[ -d "$retired_parent" && ! -L "$retired_parent" ]] || { echo 'Canonical retired-callers directory is unsafe.' >&2; return 3; }
    retired_parent="$(cd -- "$retired_parent" && pwd -P)" || return 3
  fi
  candidate="$retired_parent/$basename"
  if [[ -n "$supplied" ]]; then
    supplied_parent="$(dirname -- "$supplied")"
    [[ -d "$supplied_parent" && ! -L "$supplied_parent" ]] || { echo 'Supplied retired caller parent is unsafe.' >&2; return 3; }
    supplied_resolved="$(cd -- "$supplied_parent" && pwd -P)/$(basename -- "$supplied")"
    [[ "$supplied_resolved" == "$candidate" ]] || { echo 'Supplied retired caller path is not the canonical counterpart.' >&2; return 3; }
  fi
  printf '%s\n' "$candidate"
}
phase12b_validate_host() {
  local file="$1" host platform mode identity sid serialization labels
  host="$(phase12b_yaml_value "$file" '.host_id')"; platform="$(phase12b_yaml_value "$file" '.platform')"; mode="$(phase12b_yaml_value "$file" '.runner.mode')"; identity="$(phase12b_yaml_value "$file" '.runner.service_identity')"; sid="$(phase12b_yaml_value "$file" '.runner.service_sid')"; serialization="$(phase12b_yaml_value "$file" '.execution.serialization')"; labels="$(phase12b_yaml_value "$file" '.runner.labels | join(",")')"
  [[ "$host" =~ ^[A-Za-z0-9_.-]+$ && "$platform" == windows && "$mode" == windows-service && "$identity" == network-service && "$sid" == S-1-5-20 && "$serialization" == global-mutex && "$labels" == 'self-hosted,Windows,X64,codex-automation' ]] || { echo 'Host configuration has missing or invalid required fields.' >&2; return 2; }
}
phase12b_resolve_host_config() {
  local environment="$1" configured base candidate
  configured="$(phase12b_yaml_value "$environment" '.host.config')"
  [[ -n "$configured" ]] || { echo 'Environment host.config is required.' >&2; return 2; }
  if [[ "$configured" =~ ^([A-Za-z]:[\\/]|/) ]]; then candidate="$configured"; else base="$(cd -- "$(dirname -- "$environment")" && pwd)"; candidate="$base/$configured"; fi
  [[ -f "$candidate" && ! -L "$candidate" ]] || { echo 'Resolved host.config is missing or unsafe.' >&2; return 2; }
  phase12b_validate_host "$candidate" || return
  printf '%s\n' "$candidate"
}
phase12b_caller_runner() {
  local action="$1" host_config="$2" repository="$3" repository_id="$4" finalize="${5:-}"
  local root cli
  root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  cli="$root/scripts/host/caller-runner.ps1"
  [[ -f "$cli" && ! -L "$cli" ]] || { echo 'Canonical caller runner entry point is missing or unsafe.' >&2; return 2; }
  command -v powershell.exe >/dev/null 2>&1 || { echo 'powershell.exe is required for canonical host orchestration.' >&2; return 127; }
  local args=(-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$cli" -Action "$action" -HostConfig "$host_config" -RepositoryFullName "$repository" -RepositoryId "$repository_id")
  [[ "$finalize" != begin ]] || args+=(-BeginRetirement)
  [[ "$finalize" != finalize ]] || args+=(-FinalizeRetirement)
  phase12b_test_mode && args+=(-TestMode -FixtureRoot "$(phase12b_test_fixture_root)")
  powershell.exe "${args[@]}"
}
phase12b_plan_or_apply() {
  case "${1:-plan}" in
    plan) return 0 ;;
    apply) if [[ "${2:-}" != --approve ]]; then echo 'Mutation requires --apply --approve.' >&2; return 2; fi ;;
    *) echo 'Mode must be plan or apply.' >&2; return 2 ;;
  esac
}

phase12b_audit() {
  printf 'AUDIT_EVENT=%s\nAUDIT_REPOSITORY=%s\nAUDIT_MODE=%s\n' "$1" "${2:-}" "${3:-plan}"
}
