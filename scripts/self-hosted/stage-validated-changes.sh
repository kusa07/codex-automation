#!/usr/bin/env bash
set -euo pipefail

# Trusted publication boundary. The caller must first verify HEAD, refs, config,
# remote and base SHA. No Issue field is an argument to this script.
[[ $# -eq 6 ]] || { echo 'Expected workspace, mode, fixture path, fixture content, trusted auth file, and ownership marker digest' >&2; exit 2; }
workspace="$1"
mode="$2"
fixture_path="$3"
fixture_content="$4"
trusted_auth_file="$5"
expected_marker_hash="$6"
case "${mode}" in
  general) [[ -z "${fixture_path}" && -z "${fixture_content}" ]] || exit 1 ;;
  fixture) [[ -n "${fixture_path}" && -f "${fixture_content}" ]] || exit 1 ;;
  *) exit 1 ;;
esac
[[ -d "${workspace}" && ! -L "${workspace}" ]] || exit 1
[[ -f "${trusted_auth_file}" && ! -L "${trusted_auth_file}" ]] || exit 1
[[ "${expected_marker_hash}" =~ ^[0-9a-f]{64}$ ]] || exit 1
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
reparse_script="$(cygpath -aw -- "${script_dir}/assert-no-reparse.ps1")"
workspace_windows="$(cygpath -aw -- "${workspace}")"
check_windows_path() {
  CODEX_REPARSE_ROOT="${workspace_windows}" CODEX_REPARSE_RELATIVE="$1" \
    pwsh -NoProfile -NonInteractive -File "${reparse_script}" >/dev/null
}
check_marker() {
  local marker="${workspace}/.codex-workspace-owned.json"
  check_windows_path '.codex-workspace-owned.json'
  [[ -f "${marker}" && ! -L "${marker}" ]] || exit 1
  [[ "$(sha256sum -- "${marker}" | cut -d ' ' -f 1)" == "${expected_marker_hash}" ]] || exit 1
}
check_windows_path ''
check_marker
git -C "${workspace}" diff --cached --quiet -- || exit 1

temporary_directory="$(mktemp -d)"
trap 'rm -f -- "${temporary_directory}/status" "${temporary_directory}/index" "${temporary_directory}/paths" "${temporary_directory}/staged" "${temporary_directory}/ignored"; rmdir -- "${temporary_directory}"' EXIT
git -C "${workspace}" status --porcelain=v1 -z --untracked-files=all > "${temporary_directory}/status"

declare -a changed_paths=()
contains_path() {
  local wanted="$1" candidate
  for candidate in "${changed_paths[@]}"; do
    [[ "${candidate}" != "${wanted}" ]] || return 0
  done
  return 1
}
path_is_forbidden() {
  local path="${1,,}"
  case "${path}" in
    .git|.git/*|*/.git|*/.git/*|.github/workflows/*|.github/actions/*|agents.md|*/agents.md|.gitmodules|*/.gitmodules|.gitattributes|*/.gitattributes|.gitignore|*/.gitignore|auth.json|*/auth.json|gha-creds-*.json|*/gha-creds-*.json|credentials*.json|*/credentials*.json|service-account*.json|*/service-account*.json|.env|*/.env|.env.local|*/.env.local|.env.*.local|*/.env.*.local|*.pem|*.key|id_rsa*|*/id_rsa*|id_ed25519*|*/id_ed25519*) return 0 ;;
  esac
  return 1
}
check_ignored_paths() {
  local ignored_path
  git -C "${workspace}" ls-files --others --ignored --exclude-standard -z -- > "${temporary_directory}/ignored"
  while IFS= read -r -d '' ignored_path; do
    check_windows_path "${ignored_path%/}"
    if path_is_forbidden "${ignored_path%/}"; then
      echo 'An ignored protected or credential-like path was created' >&2
      exit 1
    fi
    [[ ! -L "${workspace}/${ignored_path%/}" ]] || exit 1
    if [[ -f "${workspace}/${ignored_path}" ]] && cmp -s -- "${workspace}/${ignored_path}" "${trusted_auth_file}"; then
      echo 'An ignored file matches the caller authentication payload' >&2
      exit 1
    fi
  done < "${temporary_directory}/ignored"
}
check_path() {
  local path="$1" prefix part
  [[ -n "${path}" && "${path}" != /* && "${path}" != *\\* && "${path}" != *:* && "${path}" != *$'\n'* && "${path}" != *$'\r'* && "${path}" != *$'\t'* ]] || exit 1
  [[ "${path}" != . && "${path}" != .. && "${path}" != ../* && "${path}" != */../* && "${path}" != */.. && "${path}" != ./* && "${path}" != */./* && "${path}" != */. ]] || exit 1
  if path_is_forbidden "${path}"; then
    echo 'A protected or credential-like path was modified' >&2
    exit 1
  fi
  check_windows_path "${path}"
  prefix="${workspace}"
  IFS='/' read -r -a components <<< "${path}"
  for part in "${components[@]}"; do
    [[ -n "${part}" ]] || exit 1
    prefix="${prefix}/${part}"
    [[ ! -L "${prefix}" ]] || exit 1
  done
  if [[ -e "${workspace}/${path}" ]]; then
    [[ -f "${workspace}/${path}" ]] || exit 1
    if cmp -s -- "${workspace}/${path}" "${trusted_auth_file}"; then
      echo 'A file matches the caller authentication payload' >&2
      exit 1
    fi
  else
    git --literal-pathspecs -C "${workspace}" ls-files --error-unmatch -- "${path}" >/dev/null 2>&1 || exit 1
  fi
  git --literal-pathspecs -C "${workspace}" ls-files --stage -z -- "${path}" > "${temporary_directory}/index"
  while IFS= read -r -d '' index_entry; do
    case "${index_entry%% *}" in
      120000|160000) exit 1 ;;
    esac
  done < "${temporary_directory}/index"
  if ! contains_path "${path}"; then
    changed_paths+=("${path}")
  fi
}

while IFS= read -r -d '' status_entry; do
  [[ ${#status_entry} -ge 4 && "${status_entry:2:1}" == ' ' ]] || exit 1
  status_code="${status_entry:0:2}"
  path="${status_entry:3}"
  if [[ "${status_code}" == '??' && "${path}" == '.codex-workspace-owned.json' ]]; then
    continue
  fi
  check_path "${path}"
  if [[ "${status_code}" == *R* || "${status_code}" == *C* ]]; then
    IFS= read -r -d '' old_path || exit 1
    check_path "${old_path}"
  fi
done < "${temporary_directory}/status"
check_marker
check_ignored_paths
[[ ${#changed_paths[@]} -gt 0 ]] || { echo 'Codex produced no allowed changes' >&2; exit 1; }

if [[ "${mode}" == fixture ]]; then
  [[ ${#changed_paths[@]} -eq 1 && "${changed_paths[0]}" == "${fixture_path}" ]] || exit 1
  [[ -f "${workspace}/${fixture_path}" && ! -L "${workspace}/${fixture_path}" ]] || exit 1
  cmp -s -- "${workspace}/${fixture_path}" "${fixture_content}" || exit 1
fi

printf '%s\0' "${changed_paths[@]}" > "${temporary_directory}/paths"
# The NUL-delimited pathspec is the complete validated set, never a repository-wide add.
git --literal-pathspecs -C "${workspace}" add --pathspec-from-file="${temporary_directory}/paths" --pathspec-file-nul
git -C "${workspace}" diff --cached --name-only --no-renames -z -- > "${temporary_directory}/staged"
staged_count=0
while IFS= read -r -d '' staged_path; do
  contains_path "${staged_path}" || exit 1
  staged_count=$((staged_count + 1))
done < "${temporary_directory}/staged"
[[ ${staged_count} -eq ${#changed_paths[@]} ]] || exit 1
for path in "${changed_paths[@]}"; do
  check_windows_path "${path}"
  [[ ! -L "${workspace}/${path}" ]] || exit 1
  git --literal-pathspecs -C "${workspace}" ls-files --stage -z -- "${path}" > "${temporary_directory}/index"
  while IFS= read -r -d '' index_entry; do
    case "${index_entry%% *}" in
      120000|160000) exit 1 ;;
    esac
  done < "${temporary_directory}/index"
done
git -C "${workspace}" diff --cached --check -- >/dev/null 2>&1 || { echo 'Staged diff validation failed' >&2; exit 1; }
git -C "${workspace}" diff --quiet --
git -C "${workspace}" ls-files --others --exclude-standard -z -- > "${temporary_directory}/index"
while IFS= read -r -d '' remaining_untracked; do
  [[ "${remaining_untracked}" == '.codex-workspace-owned.json' ]] || exit 1
done < "${temporary_directory}/index"
check_ignored_paths
check_marker
echo 'Trusted changed-path validation and limited staging passed'
