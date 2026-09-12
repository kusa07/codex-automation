#!/usr/bin/env bash
# Classify sanitized Codex stderr without emitting or accepting its contents.
# The caller is responsible for mapping the fixed code to RESULT_* fields.
set -euo pipefail

[[ $# == 1 && -r "$1" ]] || {
  printf '%s\n' CODEX_EXECUTION_FAILED
  exit 0
}

stderr_file="$1"
if grep -Eqi 'unauthori[sz]ed|authentication|not authenticated|login required|credential|invalid (access )?token|expired (access )?token|(access|refresh) token (was )?(rejected|invalid|expired)' -- "$stderr_file"; then
  printf '%s\n' CODEX_AUTH_FAILED
elif grep -Eqi 'sandbox|permission denied|access denied|operation not permitted|(^|[^A-Za-z])EACCES([^A-Za-z]|$)|(^|[^A-Za-z])EPERM([^A-Za-z]|$)' -- "$stderr_file"; then
  printf '%s\n' CODEX_SANDBOX_OR_PERMISSION_FAILED
elif grep -Eqi 'unknown option|unrecognized option|unexpected argument|invalid (argument|configuration)|usage:' -- "$stderr_file"; then
  printf '%s\n' CODEX_CLI_OR_CONFIGURATION_FAILED
elif grep -Eqi 'network|connection|connect|timed out|timeout|ECONN|TLS|DNS|transport' -- "$stderr_file"; then
  printf '%s\n' CODEX_NETWORK_OR_TRANSPORT_FAILED
elif grep -Eqi 'model|service unavailable|rate limit|token (limit|budget)|context (window|length)|quota|overloaded|internal server|(^|[^0-9])5[0-9]{2}([^0-9]|$)' -- "$stderr_file"; then
  printf '%s\n' CODEX_MODEL_OR_SERVICE_FAILED
else
  printf '%s\n' CODEX_EXECUTION_FAILED
fi
