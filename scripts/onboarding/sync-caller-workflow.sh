#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 --existing FILE --target FILE [--known-old FILE]... [--mode plan|apply --approve]"; }
mode=plan; approval=''; existing=''; target=''; known_old=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --existing) existing="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --known-old) known_old+=("${2:-}"); shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --approve) approval=--approve; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$existing" && -n "$target" ]] || { usage >&2; exit 2; }
case "$mode" in plan) ;; apply) [[ "$approval" == --approve ]] || { echo 'Mutation requires --mode apply --approve.' >&2; exit 2; } ;; *) echo 'Mode must be plan or apply.' >&2; exit 2 ;; esac
[[ -f "$target" && ! -L "$target" ]] || { echo 'Target rendered workflow is unsafe or missing.' >&2; exit 2; }

if [[ ! -e "$existing" ]]; then
  state=ABSENT
elif [[ ! -f "$existing" || -L "$existing" ]]; then
  state=DIVERGED
elif cmp -s "$existing" "$target"; then
  state=EXACT_TARGET
else
  state=DIVERGED
  for old in "${known_old[@]}"; do
    [[ -f "$old" && ! -L "$old" ]] || { echo 'Known-old workflow is unsafe or missing.' >&2; exit 2; }
    if cmp -s "$existing" "$old"; then state=MANAGED_OLD; break; fi
  done
fi

printf 'WORKFLOW_STATE=%s\nMODE=%s\n' "$state" "$mode"
case "$state" in
  DIVERGED) echo 'Unexpected workflow differences are fail-closed.' >&2; exit 3 ;;
  MANAGED_OLD) echo 'WORKFLOW_ACTION=REQUIRES_EXPLICIT_REVIEW' ;;
  ABSENT) echo 'WORKFLOW_ACTION=CREATE_CANDIDATE' ;;
  EXACT_TARGET) echo 'WORKFLOW_ACTION=NO_CHANGE' ;;
esac

if [[ "$mode" == apply && "$state" == MANAGED_OLD ]]; then
  cp -- "$target" "$existing"
  cmp -s "$existing" "$target" || { echo 'Post-sync exact equality failed.' >&2; exit 1; }
  echo 'SYNC_APPLY=PASS'
elif [[ "$mode" == apply ]]; then
  echo 'SYNC_APPLY=NOT_APPLICABLE'
fi
