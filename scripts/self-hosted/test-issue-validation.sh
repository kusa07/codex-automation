#!/usr/bin/env bash
set -euo pipefail

repo_root="${GITHUB_WORKSPACE:-$(pwd)}"
script_dir="${repo_root}/scripts/self-hosted"
workflow="${repo_root}/.github/workflows/codex-run.yml"
win_tmp_dir="$(powershell.exe -NoProfile -NonInteractive -Command '$p=Join-Path ([IO.Path]::GetTempPath()) ("codex-issue-validation-"+[guid]::NewGuid().ToString()); New-Item -ItemType Directory -Path $p | Out-Null; $p')"
win_tmp_dir="${win_tmp_dir//$'\r'/}"
drive_letter="${win_tmp_dir:0:1}"
case "${drive_letter}" in
  A) drive_letter=a ;; B) drive_letter=b ;; C) drive_letter=c ;; D) drive_letter=d ;;
  *) printf '%s\n' 'unsupported temporary path drive' >&2; exit 69 ;;
esac
tmp_dir="/${drive_letter}${win_tmp_dir:2}"
tmp_dir="${tmp_dir//\\//}"
trap 'powershell.exe -NoProfile -NonInteractive -Command "Remove-Item -LiteralPath '\''${win_tmp_dir}'\'' -Recurse -Force -ErrorAction SilentlyContinue" || true' EXIT

command -v powershell.exe >/dev/null 2>&1 || { printf '%s\n' 'powershell.exe is required' >&2; exit 69; }
validation_script="${tmp_dir}/validate-issue.ps1"
validation_script_ps="${win_tmp_dir}\\validate-issue.ps1"
workflow_ps="${workflow}"
if [[ "${workflow_ps}" == /?/* ]]; then
  workflow_ps="${workflow_ps:1:1}:${workflow_ps:2}"
  workflow_ps="${workflow_ps//\//\\}"
fi
powershell.exe -NoProfile -NonInteractive -Command "\$lines=Get-Content -LiteralPath '${workflow_ps}'; \$start=0; while (\$lines[\$start] -notmatch 'powershell.exe -NoProfile -NonInteractive -Command -') { \$start++ }; \$end=\$start + 1; while (\$lines[\$end] -notmatch '^          POWERSHELL\$') { \$end++ }; \$lines[(\$start + 1)..(\$end - 1)] | ForEach-Object { \$_ -replace '^          ', '' } | Set-Content -LiteralPath '${validation_script_ps}' -Encoding UTF8"
[[ -s "${validation_script}" ]]

run_validation() {
  local issue_json="$1"
  local case_win_dir="${win_tmp_dir}\\case-${RANDOM}"
  powershell.exe -NoProfile -NonInteractive -Command "New-Item -ItemType Directory -Path '${case_win_dir}' | Out-Null"
  export ISSUE_JSON="${issue_json}"
  export ISSUE_RESPONSE_FILE="${case_win_dir}\\issue.json"
  export ISSUE_NUMBER=17
  export CODEX_TASK_FILE="${case_win_dir}\\task.md"
  export EXPECTED_PATH_FILE="${case_win_dir}\\expected-path.txt"
  export EXPECTED_CONTENT_FILE="${case_win_dir}\\expected-content.txt"
  powershell.exe -NoProfile -NonInteractive -Command "[IO.File]::WriteAllText('${case_win_dir}\\issue.json',\$env:ISSUE_JSON)"
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${validation_script_ps}"
}

valid='{"state":"open","pull_request":null,"labels":[{"name":"codex-ready"}],"title":"[CA-P10-033] Phase 10 real Issue-to-Draft-PR E2E validation","body":"path: ca-p10-033-e2e/issue-17.txt\ncontent: CA-P10-033 E2E validation from Issue #17"}'
run_validation "${valid}"
powershell.exe -NoProfile -NonInteractive -Command "if ([IO.File]::ReadAllText('${EXPECTED_PATH_FILE}') -cne 'ca-p10-033-e2e/issue-17.txt') { exit 1 }; if ([IO.File]::ReadAllText('${EXPECTED_CONTENT_FILE}') -cne 'CA-P10-033 E2E validation from Issue #17') { exit 1 }"

invalid_title='{"state":"open","pull_request":null,"labels":[{"name":"codex-ready"}],"title":"wrong title","body":"path: ca-p10-033-e2e/issue-17.txt\ncontent: CA-P10-033 E2E validation from Issue #17"}'
invalid_body='{"state":"open","pull_request":null,"labels":[{"name":"codex-ready"}],"title":"[CA-P10-033] Phase 10 real Issue-to-Draft-PR E2E validation","body":"wrong body"}'
invalid_label="${valid/codex-ready/not-codex-ready}"
invalid_missing_title='{"state":"open","pull_request":null,"labels":[{"name":"codex-ready"}],"body":"path: ca-p10-033-e2e/issue-17.txt\ncontent: CA-P10-033 E2E validation from Issue #17"}'
invalid_missing_body='{"state":"open","pull_request":null,"labels":[{"name":"codex-ready"}],"title":"[CA-P10-033] Phase 10 real Issue-to-Draft-PR E2E validation"}'
for invalid in "${invalid_title}" "${invalid_body}" "${invalid_label}" "${invalid_missing_title}" "${invalid_missing_body}"; do
  if run_validation "${invalid}" >/dev/null 2>&1; then
    printf '%s\n' 'invalid Issue unexpectedly passed' >&2
    exit 1
  fi
  powershell.exe -NoProfile -NonInteractive -Command "if (Test-Path -LiteralPath '${CODEX_TASK_FILE}') { exit 1 }"
  [[ ! -e "${tmp_dir}/downstream-reached" ]]
done

boundary_script="${tmp_dir}/boundary.sh"
boundary_win_dir="${win_tmp_dir}\\boundary-${RANDOM}"
boundary_marker="${tmp_dir}/boundary-downstream-reached"
powershell.exe -NoProfile -NonInteractive -Command "New-Item -ItemType Directory -Path '${boundary_win_dir}' | Out-Null"
boundary_issue_file="${boundary_win_dir}\\issue.json"
boundary_task_file="${boundary_win_dir}\\task.md"
boundary_expected_path_file="${boundary_win_dir}\\expected-path.txt"
boundary_expected_content_file="${boundary_win_dir}\\expected-content.txt"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "export ISSUE_RESPONSE_FILE='${boundary_issue_file}'" \
  "export CODEX_TASK_FILE='${boundary_task_file}'" \
  "export EXPECTED_PATH_FILE='${boundary_expected_path_file}'" \
  "export EXPECTED_CONTENT_FILE='${boundary_expected_content_file}'" \
  "powershell.exe -NoProfile -NonInteractive -Command - < '${validation_script}'" \
  ": > '${boundary_marker}'" > "${boundary_script}"
export ISSUE_JSON="${invalid_title}"
powershell.exe -NoProfile -NonInteractive -Command "[IO.File]::WriteAllText('${boundary_issue_file}',\$env:ISSUE_JSON)"
if "${BASH:-/usr/bin/bash}" "${boundary_script}" >/dev/null 2>&1; then
  printf '%s\n' 'shell boundary unexpectedly passed' >&2
  exit 1
fi
[[ ! -e "${boundary_marker}" ]]
printf '%s\n' 'Issue validation regression tests passed'
