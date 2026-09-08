#!/usr/bin/env bash
set -euo pipefail
script_source="${BASH_SOURCE[0]//\\//}"
cygpath_bin="$(command -v cygpath 2>/dev/null || true)"
if [[ -z "$cygpath_bin" && -x /usr/bin/cygpath ]]; then cygpath_bin=/usr/bin/cygpath; fi
if [[ -z "$cygpath_bin" && -x "/c/Program Files/Git/usr/bin/cygpath.exe" ]]; then cygpath_bin="/c/Program Files/Git/usr/bin/cygpath.exe"; fi
if [[ "$script_source" =~ ^[A-Za-z]:/ ]]; then
  [[ -n "$cygpath_bin" ]] || { printf 'cygpath is required for Windows script paths\n' >&2; exit 69; }
  script_source="$($cygpath_bin -u -- "$script_source")"
fi
script_dir="$(cd -- "${script_source%/*}" && pwd -P)"
helper="${script_dir}/local-execution.ps1"
root="${CODEX_AUTOMATION_ROOT:-C:\\codex-self-hosted}"
if command -v cygpath >/dev/null 2>&1; then root="$(cygpath -aw -- "$root")"; fi
action="${1:-}"; shift || true
case "$action" in preflight|run) ;; *) printf 'usage: %s {preflight|run} [options]\n' "$0" >&2; exit 64 ;; esac
repo_id=''; run_id=''; attempt=''; command_path=''; inert=0; args=()
while (($#)); do
  case "$1" in
    --repository-id) repo_id="${2:-}"; shift 2 ;;
    --run-id) run_id="${2:-}"; shift 2 ;;
    --attempt) attempt="${2:-}"; shift 2 ;;
    --payload-path) command_path="${2:-}"; shift 2 ;;
    --payload-arg) args+=("${2:-}"); shift 2 ;;
    --inert) inert=1; shift ;;
    *) printf 'unknown option\n' >&2; exit 64 ;;
  esac
done
if command -v powershell.exe >/dev/null 2>&1; then powershell_bin=powershell.exe
elif command -v pwsh >/dev/null 2>&1; then powershell_bin=pwsh
else printf 'Windows PowerShell is required for explicit Mutex DACL support\n' >&2; exit 69; fi
if [[ "$command_path" == /* ]]; then
  [[ -n "$cygpath_bin" ]] || { printf 'cygpath is required for POSIX payload paths\n' >&2; exit 69; }
  command_path="$($cygpath_bin -aw -- "$command_path")"
fi
common=(-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$helper" -Action "$action" -Root "$root")
if [[ "$action" == run ]]; then
  common+=(-RepositoryId "$repo_id" -GithubRunId "$run_id" -GithubRunAttempt "$attempt")
  if (( inert )); then common+=(-Inert)
  elif [[ -n "$command_path" ]]; then common+=(-PayloadPath "$command_path")
  else printf 'run requires --inert or --payload-path\n' >&2; exit 64; fi
  if ((${#args[@]})); then common+=(-PayloadArgument); common+=("${args[@]}"); fi
fi
exec "$powershell_bin" "${common[@]}"
