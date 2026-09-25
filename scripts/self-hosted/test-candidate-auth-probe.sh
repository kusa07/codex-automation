#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
helper="${repo_root}/scripts/self-hosted/probe-candidate-auth.sh"
workflow="${repo_root}/.github/workflows/codex-run.yml"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p -- "${test_root}/bin" "${test_root}/managed/codex-home" "${test_root}/runner-temp"

cat > "${test_root}/bin/gcloud" <<'MOCK_GCLOUD'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-} ${2:-} ${3:-}" == 'secrets versions list' || "${1:-} ${2:-} ${3:-}" == 'secrets versions access' ]] || exit 1
if [[ "$3" == list ]]; then
  count=0
  if [[ -f "${MOCK_ROOT}/list-count.txt" ]]; then count="$(<"${MOCK_ROOT}/list-count.txt")"; fi
  count=$((count + 1))
  printf '%s\n' "$count" > "${MOCK_ROOT}/list-count.txt"
  if [[ "$count" == 2 && -f "${MOCK_ROOT}/post-list-fail" ]]; then exit 1; fi
  if [[ "$count" == 2 && -f "${MOCK_ROOT}/post-enabled.txt" ]]; then
    cat -- "${MOCK_ROOT}/post-enabled.txt"
  else
    cat -- "${MOCK_ROOT}/enabled.txt"
  fi
  exit 0
fi
[[ "$3" == access && "${4:-}" =~ ^[1-9][0-9]*$ ]] || exit 1
out=''
for arg in "$@"; do case "$arg" in --out-file=*) out="${arg#--out-file=}" ;; esac; done
[[ -n "$out" ]] || exit 1
printf 'fixture-auth-%s\n' "$4" > "$(cygpath -u -- "$out")"
MOCK_GCLOUD
cat > "${test_root}/bin/npm" <<'MOCK_NPM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == install && "$2" == --prefix && "$4" == '@openai/codex@0.148.0' ]] || exit 1
mkdir -p -- "$3/node_modules/.bin"
cp -- "${MOCK_ROOT}/bin/codex" "$3/node_modules/.bin/codex"
chmod 700 -- "$3/node_modules/.bin/codex"
MOCK_NPM
cat > "${test_root}/bin/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then printf '%s\n' 'codex-cli 0.148.0'; exit 0; fi
fixture_root="$(cd -- "$(dirname -- "$0")/../../../.." && pwd -P)"
mode="$(<"${fixture_root}/mock-mode.txt")"
home="$(cygpath -u -- "${CODEX_HOME}")"
version="${home##*/version-}"
if [[ "${1:-} ${2:-}" == 'login status' ]]; then
  if [[ "$version" == 12 && "$mode" == api-key-status ]]; then
    printf '%s\n' 'Logged in using API key'
  elif [[ "$version" == 12 && "$mode" == malformed-status ]]; then
    printf '%s\n' 'Unknown authentication mode'
  else
    printf '%s\n' 'Logged in using ChatGPT'
  fi
  exit 0
fi
[[ "${1:-} ${2:-}" == '--approve-for-me exec' ]] || exit 1
case "$mode" in
  old-fails) [[ "$version" != 11 ]] || { printf '%s\n' 'authentication failed' >&2; exit 1; } ;;
  candidate-fails) [[ "$version" != 12 ]] || { printf '%s\n' 'authentication failed' >&2; exit 1; } ;;
  both-fail) printf '%s\n' 'authentication failed' >&2; exit 1 ;;
  both-pass|api-key-status|malformed-status) ;;
  *) exit 1 ;;
esac
out=''
while (($#)); do
  if [[ "$1" == --output-last-message ]]; then out="$2"; break; fi
  shift
done
[[ -n "$out" ]] || exit 1
printf 'OK\n' > "$(cygpath -u -- "$out")"
MOCK_CODEX
chmod 700 -- "${test_root}/bin/gcloud" "${test_root}/bin/npm" "${test_root}/bin/codex"

export MOCK_ROOT="${test_root}"
export GITHUB_REPOSITORY_ID=123 GITHUB_RUN_ID=456 GITHUB_RUN_ATTEMPT=1
export GOOGLE_CLOUD_PROJECT_ID=test-project CONNECTIVITY_SECRET_ID=codex-auth-test
export CODEX_VERSION=0.148.0 CODEX_AUTOMATION_ROOT="$(cygpath -aw -- "${test_root}/managed")"
export RUNNER_TEMP="$(cygpath -aw -- "${test_root}/runner-temp")"
export PATH="${test_root}/bin:${PATH}"
printf '11\n12\n' > "${test_root}/enabled.txt"
printf '%s\n' old-fails > "${test_root}/mock-mode.txt"
output="$(bash "${helper}" "$(cygpath -aw -- "${repo_root}")")"
[[ "${output}" == *'AUTH_PROBE_VERSION=11 RESULT=FAIL CATEGORY=CODEX_AUTH_FAILED'* ]]
[[ "${output}" == *'AUTH_PROBE_VERSION=12 RESULT=PASS CATEGORY=NONE'* ]]
[[ "${output}" == *'AUTH_PROBE_BOTH_VERSIONS_TESTED=true'* ]]
[[ "$(<"${test_root}/list-count.txt")" == 2 ]]
[[ "${output}" != *'fixture-auth'* && "${output}" != *'authentication failed'* ]]
[[ -z "$(find "${test_root}/managed/codex-home" -mindepth 1 -print -quit)" ]]
[[ -z "$(find "${test_root}/runner-temp" -mindepth 1 -print -quit)" ]]

for mode in candidate-fails both-fail both-pass api-key-status malformed-status; do
  printf '%s\n' "$mode" > "${test_root}/mock-mode.txt"
  rm -f -- "${test_root}/list-count.txt"
  output="$(bash "${helper}" "$(cygpath -aw -- "${repo_root}")")"
  [[ "${output}" == *'AUTH_PROBE_BOTH_VERSIONS_TESTED=true'* ]]
  [[ "$(<"${test_root}/list-count.txt")" == 2 ]]
  if [[ "$mode" == candidate-fails || "$mode" == both-fail || "$mode" == api-key-status || "$mode" == malformed-status ]]; then
    [[ "${output}" == *'AUTH_PROBE_VERSION=12 RESULT=FAIL CATEGORY=CODEX_AUTH_FAILED'* ]]
    [[ "${output}" != *'AUTH_PROBE_VERSION=12 RESULT=PASS'* ]]
  fi
  [[ -z "$(find "${test_root}/managed/codex-home" -mindepth 1 -print -quit)" ]]
  [[ -z "$(find "${test_root}/runner-temp" -mindepth 1 -print -quit)" ]]
done

printf '12\n11\n' > "${test_root}/post-enabled.txt"
rm -f -- "${test_root}/list-count.txt"
output="$(bash "${helper}" "$(cygpath -aw -- "${repo_root}")")"
[[ "${output}" == *'AUTH_PROBE_BOTH_VERSIONS_TESTED=true'* ]]
rm -f -- "${test_root}/post-enabled.txt" "${test_root}/list-count.txt"

printf '%s\n' old-fails > "${test_root}/mock-mode.txt"
for post in $'11\n13\n' $'11\nlatest\n' $'11\n11\n'; do
  printf '%s' "$post" > "${test_root}/post-enabled.txt"
  rm -f -- "${test_root}/list-count.txt"
  if bash "${helper}" "$(cygpath -aw -- "${repo_root}")" > "${test_root}/result.txt" 2>/dev/null; then
    echo 'Post-probe enabled-set drift was accepted' >&2
    exit 1
  fi
  ! grep -F 'AUTH_PROBE_BOTH_VERSIONS_TESTED=true' "${test_root}/result.txt" >/dev/null
  [[ -z "$(find "${test_root}/managed/codex-home" -mindepth 1 -print -quit)" ]]
  [[ -z "$(find "${test_root}/runner-temp" -mindepth 1 -print -quit)" ]]
done
rm -f -- "${test_root}/post-enabled.txt" "${test_root}/list-count.txt"
: > "${test_root}/post-list-fail"
if bash "${helper}" "$(cygpath -aw -- "${repo_root}")" > "${test_root}/result.txt" 2>/dev/null; then
  echo 'Post-probe metadata read failure was accepted' >&2
  exit 1
fi
! grep -F 'AUTH_PROBE_BOTH_VERSIONS_TESTED=true' "${test_root}/result.txt" >/dev/null
rm -f -- "${test_root}/post-list-fail"

for invalid in $'11\n' $'11\n12\n13\n' $'11\n11\n' $'11\nlatest\n'; do
  printf '%s' "${invalid}" > "${test_root}/enabled.txt"
  rm -f -- "${test_root}/list-count.txt"
  if bash "${helper}" "$(cygpath -aw -- "${repo_root}")" > "${test_root}/result.txt" 2>/dev/null; then
    echo 'Invalid enabled-version state was accepted' >&2
    exit 1
  fi
  [[ -z "$(find "${test_root}/managed/codex-home" -mindepth 1 -print -quit)" ]]
  [[ -z "$(find "${test_root}/runner-temp" -mindepth 1 -print -quit)" ]]
done

# Exercise the actual workflow relocation block with a native Windows source
# path; Bash checks the canonical POSIX form before moving the fixture.
awk '
  /^      - name: Relocate temporary Google credential outside automation checkout$/ { step=1; next }
  step && /^      - name:/ { exit }
  step && /^        run: \|$/ { body=1; next }
  body { sub(/^          /, ""); print }
' "${workflow}" > "${test_root}/relocate.sh"
[[ -s "${test_root}/relocate.sh" ]]
mkdir -- "${test_root}/workspace"
printf '%s\n' fixture-google-credential > "${test_root}/workspace/gha-creds.json"
export GITHUB_WORKSPACE="$(cygpath -aw -- "${test_root}/workspace")"
export GOOGLE_GHA_CREDS_PATH="$(cygpath -aw -- "${test_root}/workspace/gha-creds.json")"
export GITHUB_ENV="${test_root}/github-env"
bash "${test_root}/relocate.sh"
relocated="${test_root}/runner-temp/codex-candidate-google-credentials-456-1.json"
[[ -f "${relocated}" && ! -e "${test_root}/workspace/gha-creds.json" ]]
grep -F 'CANDIDATE_GOOGLE_CREDS_CREATED=true' "${GITHUB_ENV}" >/dev/null
rm -f -- "${relocated}"

# The diagnostic mode is exclusive and the normal write/read-only jobs keep
# their own Secret preflight rather than inheriting the two-version exception.
grep -F 'candidate_auth_validation_mode:' "${workflow}" >/dev/null
grep -F 'if: ${{ inputs.candidate_auth_validation_mode == true && inputs.validation_mode != true && inputs.workspace_write_validation_mode != true }}' "${workflow}" >/dev/null
grep -F 'name: Complete self-hosted candidate authentication diagnostic' "${workflow}" >/dev/null
grep -F 'AUTH_PROBE_COMPLETE=true' "${workflow}" >/dev/null
grep -F 'inputs.validation_mode != true && inputs.candidate_auth_validation_mode != true' "${workflow}" >/dev/null
grep -F 'Expected exactly one enabled authentication version' "${workflow}" >/dev/null
printf '%s\n' 'Candidate authentication probe tests passed'
