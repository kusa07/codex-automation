#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bootstrap.sh --project-id PROJECT_ID --trusted-owner-id OWNER_ID [options]

Options:
  --pool-id ID                    Default: github
  --provider-id ID                Default: github-actions
  --workflow-identity VALUE       Default: kusa07/codex-automation/.github/workflows/codex-run.yml
  --approved-workflow-shas LIST   Comma-separated 40-character commit SHAs

The Google Cloud Project and billing configuration must already exist.
If no approved SHA is supplied, the Provider condition is created with a
non-matching sentinel. No GitHub token can pass until a SHA is initialized.
USAGE
}

PROJECT_ID="${PROJECT_ID:-}"
TRUSTED_OWNER_ID="${TRUSTED_OWNER_ID:-}"
POOL_ID="${POOL_ID:-github}"
PROVIDER_ID="${PROVIDER_ID:-github-actions}"
WORKFLOW_IDENTITY="${WORKFLOW_IDENTITY:-kusa07/codex-automation/.github/workflows/codex-run.yml}"
APPROVED_WORKFLOW_SHAS="${APPROVED_WORKFLOW_SHAS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="${2:-}"; shift 2 ;;
    --trusted-owner-id) TRUSTED_OWNER_ID="${2:-}"; shift 2 ;;
    --pool-id) POOL_ID="${2:-}"; shift 2 ;;
    --provider-id) PROVIDER_ID="${2:-}"; shift 2 ;;
    --workflow-identity) WORKFLOW_IDENTITY="${2:-}"; shift 2 ;;
    --approved-workflow-shas) APPROVED_WORKFLOW_SHAS="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; exit 1; }
}

validate_id() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[a-z][a-z0-9-]{3,31}$ ]] || {
    echo "$label must match ^[a-z][a-z0-9-]{3,31}$" >&2
    exit 2
  }
}

[[ -n "$PROJECT_ID" ]] || { echo "PROJECT_ID is required." >&2; exit 2; }
[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "Invalid PROJECT_ID format." >&2; exit 2; }
[[ "$TRUSTED_OWNER_ID" =~ ^[0-9]+$ ]] || { echo "TRUSTED_OWNER_ID must be numeric." >&2; exit 2; }
validate_id "POOL_ID" "$POOL_ID"
validate_id "PROVIDER_ID" "$PROVIDER_ID"
[[ "$WORKFLOW_IDENTITY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] || {
  echo "Invalid WORKFLOW_IDENTITY format." >&2
  exit 2
}
require_command gcloud

build_sha_list() {
  local csv="$1" sha result="" separator=""
  if [[ -z "$csv" ]]; then
    printf "['__NO_APPROVED_WORKFLOW_SHA__']"
    return
  fi
  IFS=',' read -r -a values <<< "$csv"
  [[ ${#values[@]} -le 10 ]] || { echo "At most 10 approved SHAs are allowed." >&2; exit 2; }
  for sha in "${values[@]}"; do
    [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "Invalid workflow SHA: $sha" >&2; exit 2; }
    result+="${separator}'${sha,,}'"
    separator=", "
  done
  printf '[%s]' "$result"
}

SHA_LIST="$(build_sha_list "$APPROVED_WORKFLOW_SHAS")"
ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.repository=assertion.repository,attribute.job_workflow_ref=assertion.job_workflow_ref,attribute.job_workflow_sha=assertion.job_workflow_sha"
ATTRIBUTE_CONDITION="assertion.repository_owner_id == '${TRUSTED_OWNER_ID}' && assertion.job_workflow_ref.startsWith('${WORKFLOW_IDENTITY}@') && assertion.job_workflow_sha in ${SHA_LIST}"

echo "Validating existing Google Cloud Project: $PROJECT_ID"
gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' >/dev/null

echo "Enabling APIs required by Workload Identity Federation and Secret Manager."
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID"

if gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
  echo "Workload Identity Pool already exists: $POOL_ID"
else
  echo "Creating Workload Identity Pool: $POOL_ID"
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project="$PROJECT_ID" \
    --location=global \
    --display-name="GitHub Actions"
fi

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
  echo "Updating existing OIDC Provider: $PROVIDER_ID"
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --project="$PROJECT_ID" \
    --location=global \
    --workload-identity-pool="$POOL_ID" \
    --issuer-uri="https://token.actions.githubusercontent.com/" \
    --attribute-mapping="$ATTRIBUTE_MAPPING" \
    --attribute-condition="$ATTRIBUTE_CONDITION"
else
  echo "Creating OIDC Provider: $PROVIDER_ID"
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --project="$PROJECT_ID" \
    --location=global \
    --workload-identity-pool="$POOL_ID" \
    --display-name="GitHub Actions" \
    --issuer-uri="https://token.actions.githubusercontent.com/" \
    --attribute-mapping="$ATTRIBUTE_MAPPING" \
    --attribute-condition="$ATTRIBUTE_CONDITION"
fi

if [[ -z "$APPROVED_WORKFLOW_SHAS" ]]; then
  echo "Provider is fail-closed: no workflow SHA is approved."
  echo "Use rotate-workflow-sha.sh initialize after reviewing the committed workflow SHA."
else
  echo "Provider configured with the explicitly supplied approved workflow SHA list."
fi


