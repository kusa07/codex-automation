#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 --repository OWNER/REPO --environment FILE --private-config FILE --target-workflow-sha SHA [--mode plan|apply --approve] [test only: --test-mode --fixture-root DIR]; legacy fixture: --existing FILE --target FILE"; }
[[ -z "${PHASE12B_TEST_MODE:-}${PHASE12B_TEST_ROOT:-}${PHASE12B_INTERNAL_TEST_MODE:-}${PHASE12B_INTERNAL_TEST_ROOT:-}" ]] || { echo 'Environment-based test activation is prohibited.' >&2; exit 3; }
mode=plan; approval=''; existing=''; target=''; known_old=()
repository=''; environment=''; private_config=''; target_sha=''; current_file=''; current_sha=''; branch=''; default_branch=''; test_mode=false; fixture_root=''
cleanup=()
cleanup_files() { if ((${#cleanup[@]})); then rm -f -- "${cleanup[@]}"; fi; return 0; }
trap cleanup_files EXIT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --existing) existing="${2:-}"; shift 2;; --target) target="${2:-}"; shift 2;; --known-old) known_old+=("${2:-}"); shift 2;;
    --repository) repository="${2:-}"; shift 2;; --environment) environment="${2:-}"; shift 2;; --private-config) private_config="${2:-}"; shift 2;; --target-workflow-sha) target_sha="${2:-}"; shift 2;;
    --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; --test-mode) test_mode=true; shift;; --fixture-root) fixture_root="${2:-}"; shift 2;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"; source "$ROOT/scripts/lib/phase12b-config.sh"
$test_mode && phase12b_enable_test_mode "$fixture_root"
if ((${#known_old[@]})) && ! phase12b_test_mode; then echo 'Production --known-old authority is prohibited.' >&2; exit 3; fi

if [[ -n "$repository" ]]; then
  [[ -n "$private_config" && -n "$target_sha" ]] || { usage >&2; exit 2; }
  if phase12b_test_mode; then phase12b_assert_test_file_path "$private_config" caller;[[ -z "$environment" ]] || phase12b_assert_test_file_path "$environment" environment;fi
  if ! phase12b_test_mode; then [[ -n "$environment" ]] || { echo 'Production workflow synchronization requires environment desired state.' >&2; exit 2; }; phase12b_validate_environment "$environment"; fi
  phase12b_require_yaml_file "$private_config"; phase12b_validate_caller "$private_config"; phase12b_require_sha "$target_sha"
  configured_repo="$(phase12b_yaml_value "$private_config" '.repository.full_name')"; configured_repo_id="$(phase12b_yaml_value "$private_config" '.repository.id')"
  workflow_path="$(phase12b_yaml_value "$private_config" '.workflow.path')"; branch="$(phase12b_yaml_value "$private_config" '.workflow.branch')"; secret_id="$(phase12b_yaml_value "$private_config" '.secret.id')"
  [[ "$configured_repo" == "$repository" ]] || { echo 'Repository identity mismatch.' >&2; exit 3; }
  if ! phase12b_test_mode; then phase12b_reject_production_test_injections PHASE12B_GH_BIN PHASE12B_TEST_REPOSITORY_ID PHASE12B_TEST_DEFAULT_BRANCH PHASE12B_CURRENT_WORKFLOW_FILE PHASE12B_CURRENT_CONTENT_SHA PHASE12B_CANONICAL_TEMPLATE PHASE12B_MANAGED_OLD_WORKFLOW PHASE12B_AUTOMATION_REPOSITORY PHASE12B_AUTOMATION_WORKFLOW_PATH || exit $?; fi
  if phase12b_test_mode; then gh_bin="$(phase12b_test_fixture_root)/bin/gh";[[ -x "$gh_bin" && ! -L "$gh_bin" ]] || { echo 'Fixed test gh fixture is missing or unsafe.' >&2; exit 3; };else gh_bin=gh;command -v "$gh_bin" >/dev/null 2>&1 || { echo 'gh is required for authoritative repository/workflow read-back.' >&2; exit 127; };fi
  if phase12b_test_mode; then
    [[ -n "${PHASE12B_TEST_REPOSITORY_ID:-}" && -n "${PHASE12B_TEST_DEFAULT_BRANCH:-}" ]] || { echo 'Test repository read-back fixture is incomplete.' >&2; exit 3; }
    remote_repo_id="$PHASE12B_TEST_REPOSITORY_ID"; remote_repo_name="$repository"; default_branch="$PHASE12B_TEST_DEFAULT_BRANCH"
  else
    repo_metadata="$(phase12b_github_repository_metadata "$gh_bin" "$repository")" || exit $?
    IFS=$'\t' read -r remote_repo_id remote_repo_name default_branch <<< "$repo_metadata"
  fi
  [[ "$remote_repo_id" =~ ^[1-9][0-9]*$ && "$remote_repo_id" == "$configured_repo_id" ]] || { echo 'Authoritative repository ID does not match desired state.' >&2; exit 3; }
  phase12b_require_branch "$default_branch"
  [[ "$branch" == "$default_branch" ]] || { echo 'Desired workflow branch does not match GitHub default branch.' >&2; exit 3; }
  if phase12b_test_mode; then
    if [[ -n "${PHASE12B_CURRENT_WORKFLOW_FILE:-}" ]]; then current_file="$(phase12b_test_file_path PHASE12B_CURRENT_WORKFLOW_FILE)";current_sha="${PHASE12B_CURRENT_CONTENT_SHA:-}";[[ "$current_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Injected current workflow fixture requires a blob SHA.' >&2; exit 2; };else current_file="$(phase12b_test_fixture_root)/workflow-absent";current_sha='';fi
  else
    content_state="$(phase12b_github_content_state "$gh_bin" "repos/$repository/contents/$workflow_path?ref=$branch")" || exit $?
    case "$content_state" in
      PRESENT)
        current_file="$(mktemp)"; cleanup+=("$current_file")
        current_sha="$("$gh_bin" api "repos/$repository/contents/$workflow_path?ref=$branch" --jq '.sha')"
        [[ "$current_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Authoritative workflow blob SHA is missing or malformed.' >&2; exit 3; }
        "$gh_bin" api "repos/$repository/contents/$workflow_path?ref=$branch" --jq '.content' | tr -d '\n' | base64 -d > "$current_file";;
      ABSENT) current_file="$(mktemp)";rm -f -- "$current_file";current_sha='';;
    esac
  fi
  canonical_template="$ROOT/templates/caller/codex-connectivity-test.yml.tpl"
  if phase12b_test_mode && [[ -n "${PHASE12B_CANONICAL_TEMPLATE:-}" ]]; then canonical_template="$(phase12b_test_file_path PHASE12B_CANONICAL_TEMPLATE)"; fi
  [[ -n "$canonical_template" && -f "$canonical_template" && ! -L "$canonical_template" ]] || { echo 'Explicit canonical template/config source is required.' >&2; exit 2; }
  target="$(mktemp)"; cleanup+=("$target")
  if [[ -n "$environment" ]]; then automation_repo="$(phase12b_yaml_value "$environment" '.automation.repository')"; automation_path="$(phase12b_yaml_value "$environment" '.automation.workflow_path')"; project_id="$(phase12b_yaml_value "$environment" '.google_cloud.project_id')"; provider_resource="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_provider_resource')"; else automation_repo='kusa07/codex-automation'; automation_path='.github/workflows/codex-run.yml'; project_id=''; provider_resource=''; fi
  sed -e "s#__AUTOMATION_REPOSITORY__#$automation_repo#g" -e "s#__AUTOMATION_WORKFLOW_PATH__#$automation_path#g" -e "s#__AUTOMATION_WORKFLOW_SHA__#$target_sha#g" -e "s#__GOOGLE_CLOUD_PROJECT_ID__#$project_id#g" -e "s#__WORKLOAD_IDENTITY_PROVIDER__#$provider_resource#g" -e "s#__CODEX_AUTH_SECRET_ID__#$secret_id#g" "$canonical_template" > "$target"
  grep -qE '__[A-Z0-9_]+__' "$target" && { echo 'Canonical workflow rendering left unresolved placeholders.' >&2; exit 3; }
  if phase12b_test_mode && [[ -n "${PHASE12B_MANAGED_OLD_WORKFLOW:-}" ]]; then
    managed_old_fixture="$(phase12b_test_file_path PHASE12B_MANAGED_OLD_WORKFLOW)"
    known_old+=("$managed_old_fixture")
  elif ! phase12b_test_mode && [[ -f "$current_file" ]] && ! cmp -s "$current_file" "$target"; then
    project_id="$(phase12b_yaml_value "$environment" '.google_cloud.project_id')"; pool_id="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_pool')"; provider_id="$(phase12b_yaml_value "$environment" '.google_cloud.workload_identity_provider')"
    command -v gcloud >/dev/null 2>&1 || { echo 'gcloud is required for managed-old authority read-back.' >&2; exit 127; }
    provider_condition="$(gcloud iam workload-identity-pools providers describe "$provider_id" --project="$project_id" --location=global --workload-identity-pool="$pool_id" --format='value(attributeCondition)' 2>/dev/null)" || { echo 'Managed-old provider authority read-back failed.' >&2; exit 3; }
    approved_shas="$(phase12b_parse_wif_workflow_condition "$provider_condition" "$(phase12b_yaml_value "$environment" '.github.owner_id')" "$automation_repo" "$automation_path")" || { echo 'Managed-old provider condition is malformed, broadened, or mismatched.' >&2; exit 3; }
    [[ -n "$approved_shas" ]] || { echo 'Managed-old provider condition has no approved workflow SHA.' >&2; exit 3; }
    while IFS= read -r approved_sha; do
      [[ "$approved_sha" == "$target_sha" ]] && continue
      approved_render="$(mktemp)"; cleanup+=("$approved_render")
      sed -e "s#__AUTOMATION_REPOSITORY__#$automation_repo#g" -e "s#__AUTOMATION_WORKFLOW_PATH__#$automation_path#g" -e "s#__AUTOMATION_WORKFLOW_SHA__#$approved_sha#g" -e "s#__GOOGLE_CLOUD_PROJECT_ID__#$project_id#g" -e "s#__WORKLOAD_IDENTITY_PROVIDER__#$provider_resource#g" -e "s#__CODEX_AUTH_SECRET_ID__#$secret_id#g" "$canonical_template" > "$approved_render"
      known_old+=("$approved_render")
      legacy_template="$ROOT/templates/caller/phase10-connectivity-test.yml.tpl"
      [[ -f "$legacy_template" && ! -L "$legacy_template" ]] || { echo 'Canonical Phase 10 legacy workflow template is missing or unsafe.' >&2; exit 3; }
      legacy_render="$(mktemp)"; cleanup+=("$legacy_render")
      sed -e "s#__AUTOMATION_REPOSITORY__#$automation_repo#g" -e "s#__AUTOMATION_WORKFLOW_PATH__#$automation_path#g" -e "s#__AUTOMATION_WORKFLOW_SHA__#$approved_sha#g" -e "s#__GOOGLE_CLOUD_PROJECT_ID__#$project_id#g" -e "s#__WORKLOAD_IDENTITY_PROVIDER__#$provider_resource#g" "$legacy_template" > "$legacy_render"
      known_old+=("$legacy_render")
    done <<< "$approved_shas"
  fi
  existing="$current_file"
else
  [[ -n "$existing" && -n "$target" ]] || { usage >&2; exit 2; }
  phase12b_test_mode || { echo 'Legacy file workflow interface is test-only.' >&2; exit 3; }
  phase12b_assert_test_output_path "$existing" workflow-existing;phase12b_assert_test_file_path "$target" workflow-target
fi
case "$mode" in plan) ;; apply) [[ "$approval" == --approve ]] || { echo 'Mutation requires --mode apply --approve.' >&2; exit 2; };; *) echo 'Mode must be plan or apply.' >&2; exit 2;; esac
[[ -f "$target" && ! -L "$target" ]] || { echo 'Target rendered workflow is unsafe or missing.' >&2; exit 2; }

if [[ ! -e "$existing" ]]; then state=ABSENT
elif [[ ! -f "$existing" || -L "$existing" ]]; then state=DIVERGED
elif cmp -s "$existing" "$target"; then state=EXACT_TARGET
else
  state=DIVERGED
  fixture_prefix=''; phase12b_test_mode && fixture_prefix="$(phase12b_test_fixture_root)/"
  for old in "${known_old[@]}"; do [[ -f "$old" && ! -L "$old" ]] || { echo 'Known old workflow is unsafe or missing.' >&2; exit 2; }; if phase12b_test_mode && [[ "$old" != "$fixture_prefix"* ]]; then echo 'Known old workflow fixture escapes FixtureRoot.' >&2; exit 3; fi; cmp -s "$existing" "$old" && { state=MANAGED_OLD; break; }; done
fi
printf 'WORKFLOW_STATE=%s\nMODE=%s\n' "$state" "$mode"
[[ -z "$repository" ]] || printf 'DEFAULT_BRANCH=%s\nMUTATION_BRANCH=%s\nREADBACK_BRANCH=%s\n' "$default_branch" "$branch" "$branch"
case "$state" in DIVERGED) echo 'Unexpected workflow differences are fail-closed.' >&2; exit 3;; MANAGED_OLD) echo 'WORKFLOW_ACTION=REQUIRES_EXPLICIT_REVIEW';; ABSENT) echo 'WORKFLOW_ACTION=CREATE_CANDIDATE';; EXACT_TARGET) echo 'WORKFLOW_ACTION=NO_CHANGE';; esac

if [[ "$mode" == apply && "$state" =~ ^(MANAGED_OLD|ABSENT)$ ]]; then
  [[ "${PHASE12B_APPROVAL_TOKEN:-}" == approve-sync || "$approval" == --approve ]] || { echo 'Approval token missing.' >&2; exit 2; }
  if [[ -n "$repository" ]]; then
    encoded="$(base64 -w0 "$target")"
    put_args=(--method PUT "repos/$repository/contents/$workflow_path" -f message='Synchronize managed caller workflow' -f branch="$branch" -f content="$encoded")
    [[ "$state" != MANAGED_OLD ]] || put_args+=(-f sha="$current_sha")
    "$gh_bin" api "${put_args[@]}" >/dev/null
    readback="$(mktemp)"; cleanup+=("$readback")
    readback_sha="$("$gh_bin" api "repos/$repository/contents/$workflow_path?ref=$branch" --jq '.sha')"
    [[ "$readback_sha" =~ ^[0-9a-f]{40}$ && ( -z "$current_sha" || "$readback_sha" != "$current_sha" ) ]] || { echo 'Workflow write/read-back did not yield a new immutable blob on the intended branch.' >&2; exit 1; }
    "$gh_bin" api "repos/$repository/contents/$workflow_path?ref=$branch" --jq '.content' | tr -d '\n' | base64 -d > "$readback"
    cmp -s "$readback" "$target" || { echo 'Authoritative remote content read-back mismatch.' >&2; exit 1; }
  else
    cp -- "$target" "$existing"; cmp -s "$existing" "$target" || { echo 'Post-sync exact equality failed.' >&2; exit 1; }
  fi
  echo 'SYNC_APPLY=PASS'
elif [[ "$mode" == apply ]]; then echo 'SYNC_APPLY=NOT_APPLICABLE'; fi
