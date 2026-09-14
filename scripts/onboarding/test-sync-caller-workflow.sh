#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'uses: example@%040d\n' 0 > "$tmp/target"; cp "$tmp/target" "$tmp/exact"
grep -q 'WORKFLOW_STATE=EXACT_TARGET' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/exact" --target "$tmp/target")
printf 'uses: example@%040d\n' 1 > "$tmp/old"; cp "$tmp/old" "$tmp/known-old"
grep -q 'WORKFLOW_STATE=MANAGED_OLD' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/old" --target "$tmp/target" --known-old "$tmp/known-old")
"$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/old" --target "$tmp/target" --known-old "$tmp/known-old" --mode apply --approve >/dev/null
cmp -s "$tmp/old" "$tmp/target"
printf 'unrelated: true\n' > "$tmp/diverged"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/diverged" --target "$tmp/target" --known-old "$tmp/known-old" >/dev/null 2>&1; then exit 1; fi
echo 'workflow-sync: PASS'
