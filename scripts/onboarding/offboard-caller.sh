#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/../lib/phase12b-config.sh"
usage() { echo "Usage: $0 --caller FILE [--mode plan|apply --approve]"; }
mode=plan; approval=''; caller=''
while [[ $# -gt 0 ]]; do case "$1" in --caller) caller="${2:-}"; shift 2;; --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ -n "$caller" ]] || { usage >&2; exit 2; }; phase12b_plan_or_apply "$mode" "$approval"; phase12b_require_yaml_file "$caller"
repo="$(phase12b_yaml_value "$caller" '.repository.full_name')"; repo_id="$(phase12b_yaml_value "$caller" '.repository.id')"; secret="$(phase12b_yaml_value "$caller" '.secret.id')"; phase12b_require_secret_id "$secret"
[[ "$repo" =~ ^[^/]+/[^/]+$ && "$repo_id" =~ ^[1-9][0-9]*$ ]] || { echo 'Caller identity is incomplete.' >&2; exit 2; }
printf 'OFFBOARD_PLAN=PASS\nREPOSITORY=%s\nREPOSITORY_ID=%s\nSECRET_ID=%s\nMODE=%s\n' "$repo" "$repo_id" "$secret" "$mode"
if [[ "$mode" != plan ]]; then echo 'OFFBOARD_APPLY=NOT_IMPLEMENTED_BATCH_A' >&2; exit 3; fi
