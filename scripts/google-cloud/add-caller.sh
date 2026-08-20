#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  add-caller.sh --project-id PROJECT_ID --repository-id REPOSITORY_ID \
    --secret-id SECRET_ID [--pool-id github]

Creates the Secret when absent and grants the caller repository's federated
principal access to that Secret only. This script never handles auth.json.
USAGE
}

PROJECT_ID="${PROJECT_ID:-}"
REPOSITORY_ID="${REPOSITORY_ID:-}"
SECRET_ID="${SECRET_ID:-}"
POOL_ID="${POOL_ID:-github}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:-}"; shift 2 ;;
    --repository-id) REPOSITORY_ID="${2:-}"; shift 2 ;;
    --secret-id) SECRET_ID="${2:-}"; shift 2 ;;
    --pool-id) POOL_ID="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || { echo "Required command not found: gcloud" >&2; exit 1; }
[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "Invalid or missing PROJECT_ID." >&2; exit 2; }
[[ "$REPOSITORY_ID" =~ ^[0-9]+$ ]] || { echo "REPOSITORY_ID must be numeric." >&2; exit 2; }
[[ "$POOL_ID" =~ ^[a-z][a-z0-9-]{3,31}$ ]] || { echo "Invalid POOL_ID." >&2; exit 2; }
[[ "$SECRET_ID" =~ ^[A-Za-z][A-Za-z0-9_-]{0,254}$ ]] || { echo "Invalid or missing SECRET_ID." >&2; exit 2; }

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
[[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]] || { echo "Could not resolve PROJECT_NUMBER." >&2; exit 1; }

gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location=global >/dev/null

if gcloud secrets describe "$SECRET_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Secret already exists: $SECRET_ID"
else
  echo "Creating Secret metadata without a payload: $SECRET_ID"
  gcloud secrets create "$SECRET_ID" \
    --project="$PROJECT_ID" \
    --replication-policy=automatic
fi

MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository_id/${REPOSITORY_ID}"

for role in roles/secretmanager.secretAccessor roles/secretmanager.secretVersionManager; do
  echo "Ensuring $role on Secret $SECRET_ID for repository ID $REPOSITORY_ID"
  gcloud secrets add-iam-policy-binding "$SECRET_ID" \
    --project="$PROJECT_ID" \
    --member="$MEMBER" \
    --role="$role" \
    --quiet
done

echo "Caller Secret and Secret-level IAM are configured."
echo "No Secret payload was created. Initial auth.json seeding remains a manual trusted-machine operation."


