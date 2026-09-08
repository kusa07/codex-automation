#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
helper="${script_dir}/managed-execution-area.ps1"
root="${CODEX_AUTOMATION_ROOT:-C:\\codex-self-hosted}"

if command -v cygpath >/dev/null 2>&1; then
  root="$(cygpath -aw -- "$root")"
fi

action="${1:-}"
case "$action" in
  ensure|preflight) ;;
  *)
    printf 'usage: %s {ensure|preflight}\n' "$0" >&2
    exit 64
    ;;
esac

if command -v pwsh >/dev/null 2>&1; then
  powershell_bin=pwsh
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell_bin=powershell.exe
else
  printf 'PowerShell is required\n' >&2
  exit 69
fi

exec "$powershell_bin" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$helper" -Action "$action" -Root "$root"
