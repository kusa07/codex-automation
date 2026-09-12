#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
helper="${script_dir}/resume-trusted-publication.sh"
test_root="${TMPDIR:-/tmp}/resume-publication-${RANDOM}-${RANDOM}"
mock_bin="${test_root}/bin"
call_log="${test_root}/calls"
mkdir -p "$mock_bin"
trap 'rm -rf -- "$test_root"' EXIT

base_sha='1111111111111111111111111111111111111111'
final_sha='2222222222222222222222222222222222222222'
branch='codex/issue-17-run-12345-attempt-1'
validation_branch='codex/ca-p10-032-run-12345-attempt-1'
p11_validation_branch='codex/ca-p11-003-run-12345-attempt-1'
cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "${1:-}" in
  api)
    args="$*"
    if [[ "$args" == *"/issues/"* ]]; then response="${ISSUE_RESPONSE:-{\"number\":17,\"state\":\"open\",\"labels\":[{\"name\":\"codex-ready\"}],\"title\":\"Build requested\",\"body\":\"Please implement this.\"}}"
    elif [[ "$args" == *"git/ref/heads/${TASK_BRANCH}"* ]]; then response="{\"object\":{\"sha\":\"${REMOTE_BRANCH_SHA:-$FINAL_SHA}\"}}"
    elif [[ "$args" == *"git/ref/heads/main"* ]]; then response="{\"object\":{\"sha\":\"${REMOTE_BASE_SHA:-$BASE_SHA}\"}}"
    elif [[ "$args" == *"git/commits/${FINAL_SHA}"* ]]; then response="{\"sha\":\"$FINAL_SHA\",\"parents\":[{\"sha\":\"$PARENT_SHA\"}]}"
    elif [[ "$args" == *"/pulls"* ]]; then response="$PR_RESPONSE"
    else exit 1
    fi
    filter=''
    for ((i=1; i<=$#; i++)); do
      if [[ "${!i}" == --jq ]]; then
        j=$((i + 1)); filter="${!j}"; break
      fi
    done
    if [[ "$filter" == *'@tsv'* ]]; then
      if [[ "$response" == *'"number"'* ]]; then
        number="$(sed -nE 's/.*"number":([0-9]+).*/\1/p' <<<"$response")"
        state="$(sed -nE 's/.*"state":"([^"]+)".*/\1/p' <<<"$response")"
        [[ "$response" == *'"pull_request":'* ]] && is_pr=true || is_pr=false
        [[ "$response" == *'"name":"codex-ready"'* ]] && has_label=true || has_label=false
        [[ "$response" == *'"title":""'* ]] && has_title=false || has_title=true
        [[ "$response" == *'"body":""'* ]] && has_body=false || has_body=true
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$number" "$state" "$is_pr" "$has_label" "$has_title" "$has_body"
      elif [[ "$response" == *'"parents"'* ]]; then
        sha="$(sed -nE 's/^\{"sha":"([^"]+)".*/\1/p' <<<"$response")"
        parent="$(sed -nE 's/.*"parents":\[\{"sha":"([^"]+)".*/\1/p' <<<"$response")"
        printf '%s\t1\t%s\n' "$sha" "$parent"
      elif [[ "$response" == '[]' ]]; then
        printf '0\n'
      else
        draft="$(sed -nE 's/.*"draft":(true|false).*/\1/p' <<<"$response")"
        base="$(sed -nE 's/.*"base":\{"ref":"([^"]+)".*/\1/p' <<<"$response")"
        head="$(sed -nE 's/.*"head":\{"ref":"([^"]+)".*/\1/p' <<<"$response")"
        repo="$(sed -nE 's/.*"repo":\{"full_name":"([^"]+)".*/\1/p' <<<"$response")"
        sha="$(sed -nE 's/.*"head":\{"ref":"[^"]+","sha":"([^"]+)".*/\1/p' <<<"$response")"
        printf '1\t%s\t%s\t%s\t%s\t%s\n' "$draft" "$base" "$head" "$repo" "$sha"
      fi
    elif [[ -n "$filter" ]]; then printf '%s\n' "$response" | jq -r "$filter"; else printf '%s\n' "$response"; fi
    ;;
  pr)
    [[ "${2:-}" == create ]] || exit 1
    printf '%s\n' 'https://github.com/example/repo/pull/99'
    ;;
  *) exit 1 ;;
esac
MOCK
chmod 700 "${mock_bin}/gh"
cat > "${mock_bin}/jq" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
filter="${*: -1}"
input="$(cat)"
case "$filter" in
  '.object.sha // empty') sed -nE 's/.*"object":\{"sha":"([^"]+)".*/\1/p' <<<"$input" ;;
  '.number // empty') sed -nE 's/.*"number":([0-9]+).*/\1/p' <<<"$input" ;;
  '.state // empty') sed -nE 's/.*"state":"([^"]+)".*/\1/p' <<<"$input" ;;
  'if has("pull_request") then "true" else "false" end') [[ "$input" == *'"pull_request":'* ]] && printf 'true\n' || printf 'false\n' ;;
  'any(.labels[]?.name; . == "codex-ready")') [[ "$input" == *'"name":"codex-ready"'* ]] && printf 'true\n' || printf 'false\n' ;;
  '.title // empty') [[ "$input" == *'"title":""'* ]] && printf '\n' || sed -nE 's/.*"title":"([^"]*)".*/\1/p' <<<"$input" ;;
  '.body // empty') [[ "$input" == *'"body":""'* ]] && printf '\n' || sed -nE 's/.*"body":"([^"]*)".*/\1/p' <<<"$input" ;;
  '.sha // empty') sed -nE 's/^\{"sha":"([^"]+)".*/\1/p' <<<"$input" ;;
  '(.parents // []) | length') [[ "$input" == *'"parents":[{'* ]] && printf '1\n' || printf '0\n' ;;
  '.parents[0].sha // empty') sed -nE 's/.*"parents":\[\{"sha":"([^"]+)".*/\1/p' <<<"$input" ;;
  'length') [[ "$input" == '[]' ]] && printf '0\n' || printf '1\n' ;;
  '.[0].draft // false') sed -nE 's/.*"draft":(true|false).*/\1/p' <<<"$input" ;;
  '.[0].base.ref // empty') sed -nE 's/.*"base":\{"ref":"([^"]+)".*/\1/p' <<<"$input" ;;
  '.[0].head.ref // empty') sed -nE 's/.*"head":\{"ref":"([^"]+)".*/\1/p' <<<"$input" ;;
  '.[0].head.repo.full_name // empty') sed -nE 's/.*"repo":\{"full_name":"([^"]+)".*/\1/p' <<<"$input" ;;
  '.[0].head.sha // empty') sed -nE 's/.*"sha":"([^"]+)".*/\1/p' <<<"$input" ;;
  *) exit 1 ;;
esac
MOCK
chmod 700 "${mock_bin}/jq"

run() {
  PATH="${mock_bin}:$PATH" GH_CALL_LOG="$call_log" TASK_BRANCH="$branch" BASE_SHA="$base_sha" FINAL_SHA="$final_sha" PARENT_SHA="${PARENT_SHA:-$base_sha}" PR_RESPONSE="${PR_RESPONSE:-[]}" ISSUE_RESPONSE="${ISSUE_RESPONSE:-}" \
    bash "$helper" --repository example/repo --base-branch main --base-sha "$base_sha" --task-branch "$branch" --expected-final-sha "$final_sha" --issue-number 17 --mode issue "$@"
}
run_validation() {
  PATH="${mock_bin}:$PATH" GH_CALL_LOG="$call_log" TASK_BRANCH="$validation_branch" BASE_SHA="$base_sha" FINAL_SHA="$final_sha" PARENT_SHA="${PARENT_SHA:-$base_sha}" PR_RESPONSE="${PR_RESPONSE:-[]}" ISSUE_RESPONSE="${ISSUE_RESPONSE:-}" \
    bash "$helper" --repository example/repo --base-branch main --base-sha "$base_sha" --task-branch "$validation_branch" --expected-final-sha "$final_sha" --mode validation "$@"
}
run_p11_validation() {
  PATH="${mock_bin}:$PATH" GH_CALL_LOG="$call_log" TASK_BRANCH="$p11_validation_branch" BASE_SHA="$base_sha" FINAL_SHA="$final_sha" PARENT_SHA="${PARENT_SHA:-$base_sha}" PR_RESPONSE="${PR_RESPONSE:-[]}" ISSUE_RESPONSE="${ISSUE_RESPONSE:-}" \
    bash "$helper" --repository example/repo --base-branch main --base-sha "$base_sha" --task-branch "$p11_validation_branch" --expected-final-sha "$final_sha" --mode validation "$@"
}
assert_no_create() { ! grep -Fqx 'pr create' "$call_log" 2>/dev/null; }

: > "$call_log"; [[ "$(run --dry-run)" == RESUME_CREATE_DRAFT_PR_READY ]]; assert_no_create
: > "$call_log"; run --dry-run >/dev/null; [[ "$(grep -c '/issues/' "$call_log")" == 1 ]]; [[ "$(grep -c '/pulls' "$call_log")" == 1 ]]; assert_no_create
: > "$call_log"; [[ "$(run)" == RESUME_DRAFT_PR_CREATED ]]; grep -Fqx 'pr create --draft --repo example/repo --base main --head codex/issue-17-run-12345-attempt-1 --title [Codex] Issue #17 recovery --body Trusted publication recovery for Issue #17 from workflow run 12345. Closes #17' "$call_log"
: > "$call_log"; export PR_RESPONSE='[{"draft":true,"base":{"ref":"main"},"head":{"ref":"codex/issue-17-run-12345-attempt-1","sha":"2222222222222222222222222222222222222222","repo":{"full_name":"example/repo"}}}]'; [[ "$(run)" == RESUME_DRAFT_PR_ALREADY_EXISTS ]]; unset PR_RESPONSE; assert_no_create
: > "$call_log"; if run --task-branch unrelated >/dev/null 2>&1; then exit 1; fi; assert_no_create
: > "$call_log"; export PARENT_SHA="$final_sha"; if run --dry-run >/dev/null 2>&1; then exit 1; fi; unset PARENT_SHA; assert_no_create
: > "$call_log"; export REMOTE_BRANCH_SHA="$base_sha"; if run --dry-run >/dev/null 2>&1; then exit 1; fi; unset REMOTE_BRANCH_SHA; assert_no_create
: > "$call_log"; export REMOTE_BASE_SHA="$final_sha"; if run --dry-run >/dev/null 2>&1; then exit 1; fi; unset REMOTE_BASE_SHA; assert_no_create
: > "$call_log"; if bash "$helper" --repository example/repo --base-branch main --base-sha "$base_sha" --task-branch "$branch" --expected-final-sha "$final_sha" --issue-number 18 --mode issue --dry-run >/dev/null 2>&1; then exit 1; fi; assert_no_create
: > "$call_log"; export PR_RESPONSE='[{"draft":false,"base":{"ref":"main"},"head":{"ref":"codex/issue-17-run-12345-attempt-1"}}]'; if run >/dev/null 2>&1; then exit 1; fi; unset PR_RESPONSE; assert_no_create
: > "$call_log"; export PR_RESPONSE='[{"draft":true,"base":{"ref":"main"},"head":{"ref":"codex/issue-17-run-12345-attempt-1","sha":"2222222222222222222222222222222222222222","repo":{"full_name":"other/repo"}}}]'; if run >/dev/null 2>&1; then exit 1; fi; unset PR_RESPONSE; assert_no_create
: > "$call_log"; export PR_RESPONSE='[{"draft":true,"base":{"ref":"main"},"head":{"ref":"codex/issue-17-run-12345-attempt-1","sha":"1111111111111111111111111111111111111111","repo":{"full_name":"example/repo"}}}]'; if run >/dev/null 2>&1; then exit 1; fi; unset PR_RESPONSE; assert_no_create
: > "$call_log"; [[ "$(run_validation --dry-run)" == RESUME_CREATE_DRAFT_PR_READY ]]; assert_no_create
: > "$call_log"; [[ "$(run_p11_validation --dry-run)" == RESUME_CREATE_DRAFT_PR_READY ]]; ! grep -F '/issues/' "$call_log" >/dev/null
: > "$call_log"; if run_p11_validation --issue-number 17 --dry-run >/dev/null 2>&1; then exit 1; fi; assert_no_create
: > "$call_log"; export ISSUE_RESPONSE='{"number":18,"state":"open","labels":[{"name":"codex-ready"}],"title":"Build requested","body":"Please implement this."}'; if run >/dev/null 2>&1; then exit 1; fi; unset ISSUE_RESPONSE; assert_no_create
: > "$call_log"; export ISSUE_RESPONSE='{"number":17,"state":"closed","labels":[{"name":"codex-ready"}],"title":"Build requested","body":"Please implement this."}'; if run >/dev/null 2>&1; then exit 1; fi; unset ISSUE_RESPONSE; assert_no_create
: > "$call_log"; export ISSUE_RESPONSE='{"number":17,"state":"open","pull_request":{},"labels":[{"name":"codex-ready"}],"title":"Build requested","body":"Please implement this."}'; if run >/dev/null 2>&1; then exit 1; fi; unset ISSUE_RESPONSE; assert_no_create
: > "$call_log"; export ISSUE_RESPONSE='{"number":17,"state":"open","labels":[{"name":"other"}],"title":"Build requested","body":"Please implement this."}'; if run >/dev/null 2>&1; then exit 1; fi; unset ISSUE_RESPONSE; assert_no_create
: > "$call_log"; export ISSUE_RESPONSE='{"number":17,"state":"open","labels":[{"name":"codex-ready"}],"title":"","body":"Please implement this."}'; if run >/dev/null 2>&1; then exit 1; fi; unset ISSUE_RESPONSE; assert_no_create
: > "$call_log"; export ISSUE_RESPONSE='{"number":17,"state":"open","labels":[{"name":"codex-ready"}],"title":"Build requested","body":""}'; if run >/dev/null 2>&1; then exit 1; fi; unset ISSUE_RESPONSE; assert_no_create
: > "$call_log"; if run_validation --task-branch "$branch" >/dev/null 2>&1; then exit 1; fi; assert_no_create
: > "$call_log"; if run --mode validation >/dev/null 2>&1; then exit 1; fi; assert_no_create
! grep -Eq '(^|[[:space:]])git([[:space:]]|$)|codex([[:space:]]|$)' "$helper"
! grep -Eq '(^|[^[:alnum:]_])jq([^[:alnum:]_]|$)' "$helper"
printf '%s\n' 'trusted publication resume tests passed'
