#!/usr/bin/env bash
set -euo pipefail
usage() { echo "Usage: $0 --project-id PROJECT --repository-id ID --secret-id SECRET [--mode plan|apply --approve]"; }
project=''; repository_id=''; secret=''; mode=plan; approval=''
while [[ $# -gt 0 ]]; do case "$1" in --project-id) project="${2:-}"; shift 2;; --repository-id) repository_id="${2:-}"; shift 2;; --secret-id) secret="${2:-}"; shift 2;; --mode) mode="${2:-}"; shift 2;; --approve) approval=--approve; shift;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
[[ "$mode" == plan || ( "$mode" == apply && "$approval" == --approve ) ]] || { echo 'Removal requires --mode apply --approve.' >&2; exit 2; }
[[ "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ && "$repository_id" =~ ^[1-9][0-9]*$ && "$secret" =~ ^[A-Za-z][A-Za-z0-9_-]{0,254}$ ]] || { echo 'Invalid caller identity.' >&2; exit 2; }
printf 'OFFBOARD_PLAN=PASS\nPROJECT_ID=%s\nREPOSITORY_ID=%s\nSECRET_ID=%s\nMODE=%s\n' "$project" "$repository_id" "$secret" "$mode"
if [[ "$mode" == apply ]]; then echo 'No Google Cloud mutation is implemented in Batch A.' >&2; exit 3; fi
