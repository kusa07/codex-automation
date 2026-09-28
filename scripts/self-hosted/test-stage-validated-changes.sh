#!/usr/bin/env bash
set -euo pipefail

repo_root="${GITHUB_WORKSPACE:-$(pwd)}"
validator="${repo_root}/scripts/self-hosted/stage-validated-changes.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-stage-test.XXXXXX")"
case "${test_root}" in
  */codex-stage-test.*) ;;
  *) echo 'Unexpected temporary test directory' >&2; exit 1 ;;
esac
trap 'rm -rf -- "${test_root}"' EXIT
trusted_auth_file="${test_root}/trusted-auth.json"
printf '%s' 'TEST_AUTH_SECRET_MUST_NOT_BE_COMMITTED' > "${trusted_auth_file}"
stage() {
  bash "${validator}" "$@" "${trusted_auth_file}" "${marker_hash}"
}
next_repo=0
new_repo() {
  next_repo=$((next_repo + 1))
  repo="${test_root}/repo-${next_repo}"
  mkdir -p -- "${repo}/.github/workflows"
  git -C "${repo}" init -q
  git -C "${repo}" config user.name test
  git -C "${repo}" config user.email test@example.invalid
  printf '%s\n' baseline > "${repo}/README.md"
  printf '%s\n' old > "${repo}/old.txt"
  printf '%s\n' protected > "${repo}/.github/workflows/existing.yml"
  git -C "${repo}" add -- README.md old.txt .github/workflows/existing.yml
  git -C "${repo}" commit -qm baseline
  printf '%s\n' "marker-${next_repo}" > "${repo}/.codex-workspace-owned.json"
  marker_hash="$(sha256sum -- "${repo}/.codex-workspace-owned.json" | cut -d ' ' -f 1)"
}
expect_reject() {
  if stage "$@" >/dev/null 2>&1; then
    echo 'Unsafe change unexpectedly passed trusted staging' >&2
    exit 1
  fi
  git -C "$1" diff --cached --quiet -- || { echo 'Rejected change was staged' >&2; exit 1; }
}

new_repo
printf '%s\n' changed > "${repo}/README.md"
printf '%s\n' second > "${repo}/second file.txt"
stage "${repo}" general '' ''
[[ "$(git -C "${repo}" diff --cached --name-only | wc -l | tr -d ' ')" == 2 ]]
git -C "${repo}" diff --cached --name-only | grep -Fx 'README.md' >/dev/null
git -C "${repo}" diff --cached --name-only | grep -Fx 'second file.txt' >/dev/null

new_repo
printf '%s\n' changed > "${repo}/README.md"
printf '%s\n' tampered > "${repo}/.codex-workspace-owned.json"
expect_reject "${repo}" general '' ''

new_repo
expect_reject "${repo}" general '' ''

new_repo
mkdir -p -- "${repo}/ca-p10-033-e2e"
printf '%s' exact > "${repo}/ca-p10-033-e2e/issue-17.txt"
printf '%s' exact > "${test_root}/fixture-content"
stage "${repo}" fixture 'ca-p10-033-e2e/issue-17.txt' "${test_root}/fixture-content"

new_repo
mkdir -p -- "${repo}/ca-p10-033-e2e"
printf '%s' wrong > "${repo}/ca-p10-033-e2e/issue-17.txt"
expect_reject "${repo}" fixture 'ca-p10-033-e2e/issue-17.txt' "${test_root}/fixture-content"

new_repo
printf '%s\n' changed > "${repo}/.github/workflows/existing.yml"
expect_reject "${repo}" general '' ''

new_repo
printf '%s\n' secret > "${repo}/auth.json"
expect_reject "${repo}" general '' ''

new_repo
printf '%s\n' policy > "${repo}/AGENTS.md"
expect_reject "${repo}" general '' ''

new_repo
printf '%s\n' changed > "${repo}/README.md"
git -C "${repo}" add -- README.md
if stage "${repo}" general '' '' >/dev/null 2>&1; then
  echo 'Pre-staged changes unexpectedly passed' >&2
  exit 1
fi
[[ "$(git -C "${repo}" diff --cached --name-only)" == README.md ]]

new_repo
mv -- "${repo}/old.txt" "${repo}/new.txt"
stage "${repo}" general '' ''
git -C "${repo}" diff --cached --name-only --no-renames | grep -Fx old.txt >/dev/null
git -C "${repo}" diff --cached --name-only --no-renames | grep -Fx new.txt >/dev/null

new_repo
rm -- "${repo}/old.txt"
stage "${repo}" general '' ''
git -C "${repo}" diff --cached --name-only | grep -Fx old.txt >/dev/null

new_repo
printf '%s\n' changed > "${repo}/README.md"
printf '%s\n' credential > "${repo}/.env.local"
expect_reject "${repo}" general '' ''

new_repo
cp -- "${trusted_auth_file}" "${repo}/allowed-name.txt"
expect_reject "${repo}" general '' ''

new_repo
printf '%s\n' '.env' > "${repo}/.gitignore"
git -C "${repo}" add -- .gitignore
git -C "${repo}" commit -qm 'ignore environment file'
printf '%s\n' changed > "${repo}/README.md"
printf '%s\n' hidden-credential > "${repo}/.env"
expect_reject "${repo}" general '' ''

new_repo
printf '%s\n' ignored-auth-copy.txt > "${repo}/.gitignore"
git -C "${repo}" add -- .gitignore
git -C "${repo}" commit -qm 'ignore generated file'
printf '%s\n' changed > "${repo}/README.md"
cp -- "${trusted_auth_file}" "${repo}/ignored-auth-copy.txt"
expect_reject "${repo}" general '' ''

new_repo
printf '%s\n' 'ignored-dir/' > "${repo}/.gitignore"
git -C "${repo}" add -- .gitignore
git -C "${repo}" commit -qm 'ignore generated directory'
mkdir -- "${repo}/ignored-dir"
printf '%s\n' changed > "${repo}/README.md"
printf '%s\n' hidden-credential > "${repo}/ignored-dir/auth.json"
expect_reject "${repo}" general '' ''

# A local Codex process can write .git/hooks without changing status. Trusted
# publication must disable hooks even when its GitHub token is in job env.
new_repo
printf '%s\n' '#!/bin/sh' 'printf %s "$GH_TOKEN" > "$(git rev-parse --git-dir)/hook-ran"' > "${repo}/.git/hooks/pre-commit"
chmod +x "${repo}/.git/hooks/pre-commit"
printf '%s\n' changed > "${repo}/README.md"
stage "${repo}" general '' ''
GH_TOKEN=synthetic-not-a-credential git -C "${repo}" -c core.hooksPath=/dev/null -c commit.gpgSign=false -c user.name=test -c user.email=test@example.invalid commit -qm safe
[[ ! -e "${repo}/.git/hook-ran" ]]

new_repo
printf '%s\n' changed > "${repo}/README.md"
mkdir -p -- "${test_root}/junction-target"
junction_path_win="$(cygpath -aw -- "${repo}/junction")"
junction_target_win="$(cygpath -aw -- "${test_root}/junction-target")"
if CODEX_TEST_JUNCTION="${junction_path_win}" CODEX_TEST_TARGET="${junction_target_win}" \
  powershell.exe -NoProfile -NonInteractive -Command 'New-Item -ItemType Junction -Path $env:CODEX_TEST_JUNCTION -Target $env:CODEX_TEST_TARGET -ErrorAction Stop | Out-Null' >/dev/null 2>&1; then
  printf '%s\n' linked > "${repo}/junction/file.txt"
  expect_reject "${repo}" general '' ''
  printf '%s\n' 'NTFS junction rejection passed'
else
  # Still exercise the production ReparsePoint decision if this host cannot
  # create a junction (for example because of local security policy).
  CODEX_REPARSE_ROOT="$(cygpath -aw -- "${repo}")" CODEX_REPARSE_RELATIVE='README.md' \
    CODEX_REPARSE_SCRIPT="$(cygpath -aw -- "${repo_root}/scripts/self-hosted/assert-no-reparse.ps1")" \
    pwsh -NoProfile -NonInteractive -Command '. $env:CODEX_REPARSE_SCRIPT; try { Assert-AttributesNotReparse ([IO.FileAttributes]::ReparsePoint); exit 1 } catch { exit 0 }' >/dev/null
  printf '%s\n' 'NTFS junction creation unavailable; equivalent ReparsePoint decision passed'
fi

workflow="${repo_root}/.github/workflows/codex-run.yml"
write_payload="${test_root}/write-payload.sh"
awk '
  /name: Run Local Codex workspace-write and trusted publication under Mutex/ { in_write=1 }
  in_write && /^          cat > .*CODEX_PAYLOAD_FILE.*PAYLOAD/ { in_payload=1; next }
  in_payload && /^          PAYLOAD$/ { exit }
  in_payload { sub(/^          /, ""); print }
' "${workflow}" > "${write_payload}"
[[ -s "${write_payload}" ]]
bash -n "${write_payload}"
workspace_line="$(grep -n '^workspace_path=' "${write_payload}" | head -1 | cut -d: -f1)"
marker_line="$(grep -n '^ownership_marker=' "${write_payload}" | head -1 | cut -d: -f1)"
marker_use_line="$(grep -n '\${ownership_marker}' "${write_payload}" | head -1 | cut -d: -f1)"
[[ "${workspace_line}" =~ ^[1-9][0-9]*$ && "${marker_line}" =~ ^[1-9][0-9]*$ && "${marker_use_line}" =~ ^[1-9][0-9]*$ ]]
(( workspace_line < marker_line && marker_line < marker_use_line ))
grep -E '^(workspace_path|ownership_marker)=' "${write_payload}" > "${test_root}/write-marker-assignments.sh"
bash -u -c 'managed_root=/tmp/codex-managed; workspace_name=write-test; source "$1"; [[ "$ownership_marker" == /tmp/codex-managed/workspaces/write-test/.codex-workspace-owned.json ]]' _ "${test_root}/write-marker-assignments.sh"
CODEX_REPARSE_ROOT="$(cygpath -aw -- "${repo}")" CODEX_REPARSE_RELATIVE='README.md' \
  CODEX_REPARSE_SCRIPT="$(cygpath -aw -- "${repo_root}/scripts/self-hosted/assert-no-reparse.ps1")" \
  pwsh -NoProfile -NonInteractive -Command '. $env:CODEX_REPARSE_SCRIPT; if (Test-IsAllowedMissing ([UnauthorizedAccessException]::new()) $true) { exit 1 }; if (Test-IsAllowedMissing ([IO.FileNotFoundException]::new()) $false) { exit 1 }; if (-not (Test-IsAllowedMissing ([IO.FileNotFoundException]::new()) $true)) { exit 1 }' >/dev/null
grep -F -- '-c core.hooksPath=/dev/null -c commit.gpgSign=false' "${workflow}" >/dev/null
grep -F 'expected_marker_hash="$(sha256sum -- "${ownership_marker}"' "${workflow}" >/dev/null
[[ "$(grep -Fc 'assert_ownership_marker_path' "${workflow}")" -ge 4 ]]
grep -F 'encoded_base_branch=' "${workflow}" >/dev/null

printf '%s\n' 'Trusted changed-path and limited-staging tests passed'
