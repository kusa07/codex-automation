#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
entrypoint="${script_dir}/run-local-execution.sh"
test_root="${TEMP:-${TMP:-/tmp}}/codex-local-execution-test-${RANDOM}-${RANDOM}"
normal_log="${test_root}-normal.log"
cleanup() { rm -rf -- "$test_root" "${test_root}-busy" "$normal_log"; }
trap cleanup EXIT
export CODEX_AUTOMATION_ROOT="$test_root"
"${script_dir}/manage-execution-area.sh" ensure >/dev/null
actual_sid="$(pwsh -NoLogo -NoProfile -NonInteractive -Command '[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value')"
if [[ "$actual_sid" != 'S-1-5-21-1522072177-46615327-2561548676-1001' ]]; then
  printf 'mutex lifecycle tests skipped: current identity SID is not the approved runner SID\n'
  exit 0
fi
"$entrypoint" run --repository-id 123 --run-id 100 --attempt 1 --inert > "$normal_log"
grep -qx 'EXECUTION_FINISHED' "$normal_log"
"${script_dir}/manage-execution-area.sh" preflight >/dev/null
busy_root="${test_root}-busy"; export CODEX_AUTOMATION_ROOT="$busy_root"; "${script_dir}/manage-execution-area.sh" ensure >/dev/null
"$entrypoint" run --repository-id 123 --run-id 200 --attempt 1 --payload-path ping.exe --payload-arg -n --payload-arg 1 --payload-arg 127.0.0.1 >/dev/null &
holder=$!; sleep 0.5
if "$entrypoint" run --repository-id 123 --run-id 201 --attempt 1 --inert >/dev/null 2>&1; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; printf 'busy execution was not rejected\n' >&2; exit 1; fi
wait "$holder"; "${script_dir}/manage-execution-area.sh" preflight >/dev/null
export CODEX_AUTOMATION_ROOT="$test_root"; printf '{malformed' > "$test_root/state/current-run.json"
if "$entrypoint" run --repository-id 123 --run-id 300 --attempt 1 --inert >/dev/null 2>&1; then printf 'malformed state was not rejected\n' >&2; exit 1; fi
rm -f -- "$test_root/state/current-run.json"; "${script_dir}/manage-execution-area.sh" preflight >/dev/null
printf 'local execution control tests passed\n'
