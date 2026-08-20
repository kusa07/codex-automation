#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  rotate-workflow-sha.sh MODE --project-id PROJECT_ID --trusted-owner-id OWNER_ID \
    --new-sha SHA [options]

Modes:
  initialize   Approve NEW_SHA as the initial workflow version.
  stage        Approve OLD_SHA and NEW_SHA together during migration.
  finalize     Remove OLD_SHA and retain NEW_SHA only. Requires both
               --old-sha and --confirm-remove-old.

Options:
  --old-sha SHA
  --pool-id ID                 Default: github
  --provider-id ID             Default: github-actions
  --workflow-identity VALUE    Default: kusa07/codex-automation/.github/workflows/codex-run.yml
  --confirm-remove-old         Required only for finalize

This script updates only the Provider attribute condition. It never deletes
the Provider, Pool, Secret, or Secret version.
USAGE
}

MODE="${1:-}"
[[ -n "$MODE" ]] || { usage >&2; exit 2; }
shift

PROJECT_ID="${PROJECT_ID:-}"
TRUSTED_OWNER_ID="${TRUSTED_OWNER_ID:-}"
POOL_ID="${POOL_ID:-github}"
PROVIDER_ID="${PROVIDER_ID:-github-actions}"
WORKFLOW_IDENTITY="${WORKFLOW_IDENTITY:-kusa07/codex-automation/.github/workflows/codex-run.yml}"
OLD_SHA="${OLD_SHA:-}"
NEW_SHA="${NEW_SHA:-}"
CONFIRM_REMOVE_OLD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:-}"; shift 2 ;;
    --trusted-owner-id) TRUSTED_OWNER_ID="${2:-}"; shift 2 ;;
    --pool-id) POOL_ID="${2:-}"; shift 2 ;;
    --provider-id) PROVIDER_ID="${2:-}"; shift 2 ;;
    --workflow-identity) WORKFLOW_IDENTITY="${2:-}"; shift 2 ;;
    --old-sha) OLD_SHA="${2:-}"; shift 2 ;;
    --new-sha) NEW_SHA="${2:-}"; shift 2 ;;
    --confirm-remove-old) CONFIRM_REMOVE_OLD=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || { echo "Required command not found: gcloud" >&2; exit 1; }
[[ "$MODE" == initialize || "$MODE" == stage || "$MODE" == finalize ]] || { echo "Invalid mode: $MODE" >&2; exit 2; }
[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "Invalid or missing PROJECT_ID." >&2; exit 2; }
[[ "$TRUSTED_OWNER_ID" =~ ^[0-9]+$ ]] || { echo "TRUSTED_OWNER_ID must be numeric." >&2; exit 2; }
[[ "$POOL_ID" =~ ^[a-z][a-z0-9-]{3,31}$ ]] || { echo "Invalid POOL_ID." >&2; exit 2; }
[[ "$PROVIDER_ID" =~ ^[a-z][a-z0-9-]{3,31}$ ]] || { echo "Invalid PROVIDER_ID." >&2; exit 2; }
[[ "$WORKFLOW_IDENTITY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] || { echo "Invalid WORKFLOW_IDENTITY." >&2; exit 2; }
[[ "$NEW_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "NEW_SHA must be a 40-character commit SHA." >&2; exit 2; }

case "$MODE" in
  initialize)
    SHA_LIST="['${NEW_SHA,,}']"
    ;;
  stage)
    [[ "$OLD_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "OLD_SHA is required for stage." >&2; exit 2; }
    [[ "${OLD_SHA,,}" != "${NEW_SHA,,}" ]] || { echo "OLD_SHA and NEW_SHA must differ." >&2; exit 2; }
    SHA_LIST="['${OLD_SHA,,}', '${NEW_SHA,,}']"
    ;;
  finalize)
    [[ "$OLD_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "OLD_SHA is required for finalize." >&2; exit 2; }
    [[ "$CONFIRM_REMOVE_OLD" == true ]] || {
      echo "finalize requires --confirm-remove-old after caller migration is verified." >&2
      exit 2
    }
    SHA_LIST="['${NEW_SHA,,}']"
    ;;
esac

ATTRIBUTE_CONDITION="assertion.repository_owner_id == '${TRUSTED_OWNER_ID}' && assertion.job_workflow_ref.startsWith('${WORKFLOW_IDENTITY}@') && assertion.job_workflow_sha in ${SHA_LIST}"

gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool="$POOL_ID" >/dev/null

echo "Updating approved workflow SHA condition in mode: $MODE"
gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location=global \
  --workload-identity-pool="$POOL_ID" \
  --attribute-condition="$ATTRIBUTE_CONDITION"

case "$MODE" in
  initialize) echo "Initial workflow SHA approved." ;;
  stage) echo "Migration staged: old and new workflow SHAs are both approved." ;;
  finalize) echo "Migration finalized explicitly: old SHA removed, new SHA retained." ;;
esac


