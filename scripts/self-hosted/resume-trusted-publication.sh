#!/usr/bin/env bash
# Trusted-automation-only recovery for a verified pushed task branch whose
# Draft Pull Request is absent.  It never invokes Codex or changes Git refs.
set -euo pipefail

fail() { printf '%s\n' 'RESUME_PUBLICATION_REJECTED' >&2; exit 1; }
usage() {
  printf '%s\n' 'usage: resume-trusted-publication.sh --repository OWNER/REPO --base-branch BRANCH --base-sha SHA --task-branch BRANCH --expected-final-sha SHA --mode issue|validation [--issue-number NUMBER] [--dry-run]' >&2
  exit 64
}

repository=''; base_branch=''; base_sha=''; task_branch=''; final_sha=''; issue_number=''; mode=''; dry_run=false
while (($#)); do
  case "$1" in
    --repository) repository="${2:-}"; shift 2 ;;
    --base-branch) base_branch="${2:-}"; shift 2 ;;
    --base-sha) base_sha="${2:-}"; shift 2 ;;
    --task-branch) task_branch="${2:-}"; shift 2 ;;
    --expected-final-sha) final_sha="${2:-}"; shift 2 ;;
    --issue-number) issue_number="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail
[[ "$base_branch" =~ ^[A-Za-z0-9._/-]+$ && "$base_branch" != /* && "$base_branch" != */ ]] || fail
[[ "$base_sha" =~ ^[0-9a-f]{40}$ && "$final_sha" =~ ^[0-9a-f]{40}$ ]] || fail
[[ "$mode" == issue || "$mode" == validation ]] || fail
if [[ "$mode" == issue ]]; then
  [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || fail
  [[ "$task_branch" =~ ^codex/issue-${issue_number}-run-([1-9][0-9]*)-attempt-([1-9][0-9]*)$ ]] || fail
else
  # Validation branches intentionally have no Issue identity and therefore do
  # not perform or invent an Issue read-back.
  [[ -z "$issue_number" ]] || fail
  [[ "$task_branch" =~ ^codex/ca-(p10-032|p11-003)-run-([1-9][0-9]*)-attempt-([1-9][0-9]*)$ ]] || fail
fi
if [[ "$mode" == issue ]]; then
  run_id="${BASH_REMATCH[1]}"
else
  run_id="${BASH_REMATCH[2]}"
fi
repository_owner="${repository%%/*}"

if [[ "$mode" == issue ]]; then
  issue_endpoint="repos/${repository}/issues/${issue_number}"
  issue_snapshot="$(gh api "$issue_endpoint" --jq '[((.number // 0) | tostring), (.state // ""), (if has("pull_request") then "true" else "false" end), (if any(.labels[]?.name; . == "codex-ready") then "true" else "false" end), (if (.title // "") != "" then "true" else "false" end), (if (.body // "") != "" then "true" else "false" end)] | @tsv')" || fail
  IFS=$'\t' read -r issue_readback_number issue_state issue_is_pr issue_has_codex_ready issue_has_title issue_has_body <<<"$issue_snapshot"
  [[ "$issue_readback_number" == "$issue_number" && "$issue_state" == open && "$issue_is_pr" == false && "$issue_has_codex_ready" == true && "$issue_has_title" == true && "$issue_has_body" == true ]] || fail
fi

branch_sha="$(gh api "repos/${repository}/git/ref/heads/${task_branch}" --jq '.object.sha // empty')" || fail
[[ "$branch_sha" == "$final_sha" ]] || fail

commit_endpoint="repos/${repository}/git/commits/${final_sha}"
commit_snapshot="$(gh api "$commit_endpoint" --jq '[((.sha // "")), (((.parents // []) | length) | tostring), (.parents[0].sha // "")] | @tsv')" || fail
IFS=$'\t' read -r commit_sha parent_count parent_sha <<<"$commit_snapshot"
[[ "$commit_sha" == "$final_sha" && "$parent_count" == 1 && "$parent_sha" == "$base_sha" ]] || fail

current_base_sha="$(gh api "repos/${repository}/git/ref/heads/${base_branch}" --jq '.object.sha // empty')" || fail
[[ "$current_base_sha" == "$base_sha" ]] || fail

pr_endpoint="repos/${repository}/pulls"
pr_snapshot="$(gh api --method GET "$pr_endpoint" -f state=all -f head="${repository_owner}:${task_branch}" --jq 'if length == 0 then "0" elif length == 1 then ["1", (if .[0].draft then "true" else "false" end), (.[0].base.ref // ""), (.[0].head.ref // ""), (.[0].head.repo.full_name // ""), (.[0].head.sha // "")] | @tsv else [(length | tostring)] | @tsv end')" || fail
IFS=$'\t' read -r pr_count existing_draft existing_base existing_head existing_head_repo existing_head_sha <<<"$pr_snapshot"
[[ "$pr_count" =~ ^[0-9]+$ ]] || fail
if [[ "$pr_count" == 1 ]]; then
  [[ "$existing_draft" == true && "$existing_base" == "$base_branch" && "$existing_head" == "$task_branch" && "$existing_head_repo" == "$repository" && "$existing_head_sha" == "$final_sha" ]] || fail
  printf '%s\n' 'RESUME_DRAFT_PR_ALREADY_EXISTS'
  exit 0
fi
[[ "$pr_count" == 0 ]] || fail

if [[ "$mode" == issue ]]; then
  pr_title="[Codex] Issue #${issue_number} recovery"
  pr_body="Trusted publication recovery for Issue #${issue_number} from workflow run ${run_id}. Closes #${issue_number}"
else
  pr_title='[Codex] workspace-write validation recovery'
  pr_body="Trusted publication recovery for workflow run ${run_id}."
fi

if [[ "$dry_run" == true ]]; then
  printf '%s\n' 'RESUME_CREATE_DRAFT_PR_READY'
  exit 0
fi
pr_url="$(gh pr create --draft --repo "$repository" --base "$base_branch" --head "$task_branch" --title "$pr_title" --body "$pr_body")" || fail
[[ "$pr_url" =~ ^https://github\.com/${repository}/pull/[1-9][0-9]*$ ]] || fail
printf '%s\n' 'RESUME_DRAFT_PR_CREATED'
