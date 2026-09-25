#!/usr/bin/env bash
# Diagnostic-only service-context probe for two explicitly enabled Secret versions.
# It neither selects an authoritative version nor changes Secret Manager state.
set -euo pipefail
umask 077

[[ $# -eq 1 ]] || exit 64
automation_source="$(cygpath -u -- "$1")"
[[ -f "${automation_source}/scripts/self-hosted/classify-codex-failure.sh" ]] || exit 1
[[ "${GITHUB_REPOSITORY_ID:-}" =~ ^[1-9][0-9]*$ && "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "${GOOGLE_CLOUD_PROJECT_ID:-}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ && "${CONNECTIVITY_SECRET_ID:-}" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || exit 1
[[ "${CODEX_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ -n "${RUNNER_TEMP:-}" && -n "${CODEX_AUTOMATION_ROOT:-}" ]] || exit 1

managed_root="$(cygpath -u -- "${CODEX_AUTOMATION_ROOT}")"
runner_temp="$(cygpath -u -- "${RUNNER_TEMP}")"
operation="auth-probe-repo-${GITHUB_REPOSITORY_ID}-run-${GITHUB_RUN_ID}-attempt-${GITHUB_RUN_ATTEMPT}"
probe_root="${managed_root}/codex-home/${operation}"
enabled_file="${runner_temp}/${operation}-enabled.txt"
post_enabled_file="${runner_temp}/${operation}-enabled-post.txt"
cli_root="${runner_temp}/${operation}-cli"
created_probe=0
created_cli=0
created_enabled=0
created_post_enabled=0
cleanup() {
  local status=$?
  if (( created_probe )); then
    if [[ -L "${probe_root}" ]]; then
      status=1
    else
      rm -rf -- "${probe_root}" || status=1
    fi
  fi
  if (( created_cli )); then
    if [[ -L "${cli_root}" ]]; then
      status=1
    else
      rm -rf -- "${cli_root}" || status=1
    fi
  fi
  if (( created_enabled )); then
    rm -f -- "${enabled_file}" || status=1
  fi
  if (( created_post_enabled )); then
    rm -f -- "${post_enabled_file}" || status=1
  fi
  if (( created_probe )); then [[ ! -e "${probe_root}" ]] || status=1; fi
  if (( created_cli )); then [[ ! -e "${cli_root}" ]] || status=1; fi
  if (( created_enabled )); then [[ ! -e "${enabled_file}" ]] || status=1; fi
  if (( created_post_enabled )); then [[ ! -e "${post_enabled_file}" ]] || status=1; fi
  exit "${status}"
}
trap cleanup EXIT

[[ ! -e "${probe_root}" && ! -L "${probe_root}" && ! -e "${cli_root}" && ! -L "${cli_root}" && ! -e "${enabled_file}" && ! -L "${enabled_file}" && ! -e "${post_enabled_file}" && ! -L "${post_enabled_file}" ]] || {
  echo 'Candidate probe operation residue exists' >&2
  exit 1
}
created_enabled=1
if ! gcloud secrets versions list "${CONNECTIVITY_SECRET_ID}" \
  --project="${GOOGLE_CLOUD_PROJECT_ID}" --filter='state=ENABLED' \
  --format='value(name.basename())' > "${enabled_file}" 2>/dev/null; then
  echo 'Enabled Secret version metadata read failed' >&2
  exit 1
fi
mapfile -t enabled_versions < "${enabled_file}"
for index in "${!enabled_versions[@]}"; do
  enabled_versions[index]="${enabled_versions[index]%$'\r'}"
  [[ "${enabled_versions[index]}" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Enabled Secret version metadata is invalid' >&2
    exit 1
  }
done
[[ ${#enabled_versions[@]} -eq 2 && "${enabled_versions[0]}" != "${enabled_versions[1]}" ]] || {
  echo 'Candidate probe requires exactly two distinct enabled numeric versions' >&2
  exit 1
}

mkdir -- "${probe_root}"
created_probe=1
chmod 700 -- "${probe_root}"
created_cli=1
if ! npm install --prefix "${cli_root}" "@openai/codex@${CODEX_VERSION}" >/dev/null 2>&1; then
  echo 'Pinned Codex CLI installation failed' >&2
  exit 1
fi
export PATH="${cli_root}/node_modules/.bin:${PATH}"
[[ "$(codex --version)" == "codex-cli ${CODEX_VERSION}" ]] || {
  echo 'Pinned Codex CLI version mismatch' >&2
  exit 1
}

for version in "${enabled_versions[@]}"; do
  home="${probe_root}/version-${version}"
  mkdir -- "${home}"
  chmod 700 -- "${home}"
  secret_file="${home}/auth.json"
  result_file="${home}/result.txt"
  stderr_file="${home}/stderr.txt"
  if ! gcloud secrets versions access "${version}" --project="${GOOGLE_CLOUD_PROJECT_ID}" \
      --secret="${CONNECTIVITY_SECRET_ID}" --out-file="$(cygpath -aw -- "${secret_file}")" --quiet 2>/dev/null; then
    echo 'Exact Secret version access failed' >&2
    exit 1
  fi
  [[ -s "${secret_file}" && ! -L "${secret_file}" ]] || exit 1
  chmod 600 -- "${secret_file}"
  printf '%s\n' 'cli_auth_credentials_store = "file"' > "${home}/config.toml"
  chmod 600 -- "${home}/config.toml"
  before_hash="$(sha256sum "${secret_file}" | cut -d ' ' -f 1)"
  category='CODEX_AUTH_FAILED'
  probe_ok=false
  if login_status="$(env -i PATH="${PATH}" CODEX_HOME="$(cygpath -aw -- "${home}")" \
      HOME="$(cygpath -aw -- "${home}")" USERPROFILE="$(cygpath -aw -- "${home}")" \
      codex login status 2>&1)" && [[ "${login_status}" == *"Logged in using ChatGPT"* ]]; then
    if env -i PATH="${PATH}" CODEX_HOME="$(cygpath -aw -- "${home}")" \
        HOME="$(cygpath -aw -- "${home}")" USERPROFILE="$(cygpath -aw -- "${home}")" \
        codex --approve-for-me exec --sandbox read-only --ephemeral --skip-git-repo-check \
          --cd "$(cygpath -aw -- "${home}")" --json \
          --output-last-message "$(cygpath -aw -- "${result_file}")" \
          'Reply exactly OK. Do not use tools or inspect files.' >/dev/null 2>"${stderr_file}"; then
      if [[ -f "${result_file}" && "$(tr -d '\r\n' < "${result_file}")" == OK ]]; then
        probe_ok=true
      else
        category='CODEX_EXECUTION_FAILED'
      fi
    else
      category="$(bash "${automation_source}/scripts/self-hosted/classify-codex-failure.sh" "${stderr_file}")"
      case "${category}" in
        CODEX_AUTH_FAILED|CODEX_MODEL_OR_SERVICE_FAILED|CODEX_NETWORK_OR_TRANSPORT_FAILED|CODEX_SANDBOX_OR_PERMISSION_FAILED|CODEX_CLI_OR_CONFIGURATION_FAILED|CODEX_EXECUTION_FAILED) ;;
        *) category='CODEX_EXECUTION_FAILED' ;;
      esac
    fi
  fi
  if [[ ! -f "${secret_file}" || "$(sha256sum "${secret_file}" | cut -d ' ' -f 1)" != "${before_hash}" ]]; then
    probe_ok=false
    category='CODEX_AUTH_FAILED'
  fi
  if [[ "${probe_ok}" == true ]]; then
    printf 'AUTH_PROBE_VERSION=%s RESULT=PASS CATEGORY=NONE\n' "${version}"
  else
    printf 'AUTH_PROBE_VERSION=%s RESULT=FAIL CATEGORY=%s\n' "${version}" "${category}"
  fi
done
created_post_enabled=1
if ! gcloud secrets versions list "${CONNECTIVITY_SECRET_ID}" \
  --project="${GOOGLE_CLOUD_PROJECT_ID}" --filter='state=ENABLED' \
  --format='value(name.basename())' > "${post_enabled_file}" 2>/dev/null; then
  echo 'Post-probe enabled Secret version metadata read failed' >&2
  exit 1
fi
mapfile -t post_enabled_versions < "${post_enabled_file}"
for index in "${!post_enabled_versions[@]}"; do
  post_enabled_versions[index]="${post_enabled_versions[index]%$'\r'}"
  [[ "${post_enabled_versions[index]}" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Post-probe enabled Secret version metadata is invalid' >&2
    exit 1
  }
done
[[ ${#post_enabled_versions[@]} -eq 2 && "${post_enabled_versions[0]}" != "${post_enabled_versions[1]}" ]] || {
  echo 'Post-probe enabled Secret version set is invalid' >&2
  exit 1
}
if ! { [[ "${post_enabled_versions[0]}" == "${enabled_versions[0]}" && "${post_enabled_versions[1]}" == "${enabled_versions[1]}" ]] ||
       [[ "${post_enabled_versions[0]}" == "${enabled_versions[1]}" && "${post_enabled_versions[1]}" == "${enabled_versions[0]}" ]]; }; then
  echo 'Enabled Secret version set changed during candidate probe' >&2
  exit 1
fi
printf '%s\n' 'AUTH_PROBE_BOTH_VERSIONS_TESTED=true'
