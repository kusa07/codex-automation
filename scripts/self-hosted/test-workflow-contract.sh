#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workflow="${script_dir}/../../.github/workflows/codex-run.yml"

grep -Fqx '      codex_auth_secret_id:' "$workflow"
grep -Fqx '        required: true' <(sed -n '/codex_auth_secret_id:/,/^[^ ]/p' "$workflow")
grep -Fqx '      CONNECTIVITY_SECRET_ID: ${{ inputs.codex_auth_secret_id }}' "$workflow"
if grep -Fq 'CONNECTIVITY_SECRET_ID: codex-auth-${{ github.event.repository.name }}' "$workflow"; then
  printf 'workflow still derives the Secret ID from the repository name\n' >&2
  exit 1
fi

# The Local Codex invocation is intentionally passed only its isolated runtime
# inputs; publication and Google credentials remain outside that subprocess.
grep -Fq -- '--sandbox workspace-write' "$workflow"
grep -Fq -- 'env -i PATH="${PATH}" CODEX_HOME="${codex_home}"' "$workflow"

printf 'workflow contract tests passed\n'
