#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]//\\//}"
cygpath_bin="$(command -v cygpath 2>/dev/null || true)"
if [[ -z "$cygpath_bin" && -x /usr/bin/cygpath ]]; then cygpath_bin=/usr/bin/cygpath; fi
if [[ -z "$cygpath_bin" && -x "/c/Program Files/Git/usr/bin/cygpath.exe" ]]; then
  cygpath_bin="/c/Program Files/Git/usr/bin/cygpath.exe"
fi
if [[ "$script_source" =~ ^[A-Za-z]:/ ]]; then
  [[ -n "$cygpath_bin" ]] || { printf 'cygpath is required for Windows script paths\n' >&2; exit 69; }
  script_source="$("$cygpath_bin" -u -- "$script_source")"
fi
script_dir="$(cd -- "${script_source%/*}" && pwd -P)"
helper="${script_dir}/workspace-lifecycle.ps1"
root="${CODEX_AUTOMATION_ROOT:-C:\\codex-self-hosted}"
if [[ "$root" =~ ^[A-Za-z]:[\\/] ]]; then
  [[ -n "$cygpath_bin" ]] || { printf 'cygpath is required for Windows roots\n' >&2; exit 69; }
  root="$("$cygpath_bin" -aw -- "$root")"
fi

action="${1:-}"; shift || true
repository_url=""; local_source_path=""; expected_repository=""; base_sha=""; workspace_name=""; execution_id=""; expected_final_sha=""; active_run=0
while (($#)); do
  case "$1" in
    --repository-url) repository_url="${2:-}"; shift 2 ;;
    --local-source) local_source_path="${2:-}"; shift 2 ;;
    --expected-repository) expected_repository="${2:-}"; shift 2 ;;
    --base-sha) base_sha="${2:-}"; shift 2 ;;
    --workspace-name) workspace_name="${2:-}"; shift 2 ;;
    --execution-id) execution_id="${2:-}"; shift 2 ;;
    --expected-final-sha) expected_final_sha="${2:-}"; shift 2 ;;
    --active-run) active_run=1; shift ;;
    *) printf 'unknown option\n' >&2; exit 64 ;;
  esac
done
case "$action" in prepare|cleanup|preflight) ;; *) printf 'usage: %s {prepare|cleanup|preflight} [options]\n' "$0" >&2; exit 64 ;; esac
if [[ -n "$local_source_path" && "$local_source_path" =~ ^[A-Za-z]:[\\/] ]]; then
  [[ -n "$cygpath_bin" ]] || { printf 'cygpath is required for Windows local sources\n' >&2; exit 69; }
  local_source_path="$("$cygpath_bin" -aw -- "$local_source_path")"
fi
if command -v powershell.exe >/dev/null 2>&1; then powershell_bin=powershell.exe
elif command -v pwsh >/dev/null 2>&1; then powershell_bin=pwsh
else printf 'PowerShell is required\n' >&2; exit 69; fi
common=(-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$helper" -Action "$action" -Root "$root" -RepositoryUrl "$repository_url" -LocalSourcePath "$local_source_path" -ExpectedRepository "$expected_repository" -BaseSha "$base_sha" -WorkspaceName "$workspace_name" -ExecutionId "$execution_id")
if [[ -n "$expected_final_sha" ]]; then common+=(-ExpectedFinalSha "$expected_final_sha"); fi
if (( active_run )); then common+=(-ActiveRun); fi
exec "$powershell_bin" "${common[@]}"
