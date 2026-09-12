#!/usr/bin/env bash
# Trusted-automation-only recovery for a verified pushed task branch whose
# Draft Pull Request is absent.  It never invokes Codex or changes Git refs.
set -euo pipefail

fail() { printf '%s\n' 'RESUME_PUBLICATION_REJECTED' >&2; exit 1; }
usage() {
  printf '%s\n' 'usage: resume-trusted-publication.sh --repository OWNER/REPO --base-branch BRANCH --base-sha SHA --task-branch BRANCH --expected-final-sha SHA --issue-number NUMBER --mode issue|validation [--dry-run]' >&2
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
[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || fail
[[ "$mode" == issue || "$mode" == validation ]] || fail
if [[ "$mode" == issue ]]; then
  [[ "$task_branch" =~ ^codex/issue-${issue_number}-run-([1-9][0-9]*)-attempt-([1-9][0-9]*)$ ]] || fail
else
  # Validation branches intentionally have no Issue identity and therefore do
  # not perform or invent an Issue read-back.
  [[ "$task_branch" =~ ^codex/ca-p10-032-run-([1-9][0-9]*)-attempt-([1-9][0-9]*)$ ]] || fail
fi
run_id="${BASH_REMATCH[1]}"
repository_owner="${repository%%/*}"

if [[ "$mode" == issue ]]; then
  issue_json="$(gh api "repos/${repository}/issues/${issue_number}")" || fail
  issue_readback_number="$(jq -r '.number // empty' <<<"$issue_json")"
  issue_state="$(jq -r '.state // empty' <<<"$issue_json")"
  issue_is_pr="$(jq -r 'if has("pull_request") then "true" else "false" end' <<<"$issue_json")"
  issue_has_codex_ready="$(jq -r 'any(.labels[]?.name; . == "codex-ready")' <<<"$issue_json")"
  issue_title="$(jq -r '.title // empty' <<<"$issue_json")"
  issue_body="$(jq -r '.body // empty' <<<"$issue_json")"
  [[ "$issue_readback_number" == "$issue_number" && "$issue_state" == open && "$issue_is_pr" == false && "$issue_has_codex_ready" == true && -n "$issue_title" && -n "$issue_body" ]] || fail
fi

branch_json="$(gh api "repos/${repository}/git/ref/heads/${task_branch}")" || fail
branch_sha="$(jq -r '.object.sha // empty' <<<"$branch_json")"
[[ "$branch_sha" == "$final_sha" ]] || fail

commit_json="$(gh api "repos/${repository}/git/commits/${final_sha}")" || fail
commit_sha="$(jq -r '.sha // empty' <<<"$commit_json")"
parent_count="$(jq -r '(.parents // []) | length' <<<"$commit_json")"
parent_sha="$(jq -r '.parents[0].sha // empty' <<<"$commit_json")"
[[ "$commit_sha" == "$final_sha" && "$parent_count" == 1 && "$parent_sha" == "$base_sha" ]] || fail

base_json="$(gh api "repos/${repository}/git/ref/heads/${base_branch}")" || fail
current_base_sha="$(jq -r '.object.sha // empty' <<<"$base_json")"
[[ "$current_base_sha" == "$base_sha" ]] || fail

pr_json="$(gh api --method GET "repos/${repository}/pulls" -f state=all -f head="${repository_owner}:${task_branch}")" || fail
pr_count="$(jq -r 'length' <<<"$pr_json")"
[[ "$pr_count" =~ ^[0-9]+$ ]] || fail
if [[ "$pr_count" == 1 ]]; then
  existing_draft="$(jq -r '.[0].draft // false' <<<"$pr_json")"
  existing_base="$(jq -r '.[0].base.ref // empty' <<<"$pr_json")"
  existing_head="$(jq -r '.[0].head.ref // empty' <<<"$pr_json")"
  existing_head_repo="$(jq -r '.[0].head.repo.full_name // empty' <<<"$pr_json")"
  existing_head_sha="$(jq -r '.[0].head.sha // empty' <<<"$pr_json")"
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
