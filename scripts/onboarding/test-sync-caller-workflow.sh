#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'uses: example@%040d\n' 0 > "$tmp/target"; cp "$tmp/target" "$tmp/exact"
grep -q 'WORKFLOW_STATE=EXACT_TARGET' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/exact" --target "$tmp/target" --test-mode --fixture-root "$tmp")
grep -q 'WORKFLOW_STATE=ABSENT' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/absent" --target "$tmp/target" --test-mode --fixture-root "$tmp")
"$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/absent" --target "$tmp/target" --mode apply --approve --test-mode --fixture-root "$tmp" >/dev/null
cmp -s "$tmp/absent" "$tmp/target"
printf 'uses: example@%040d\n' 1 > "$tmp/old"; cp "$tmp/old" "$tmp/known-old"
grep -q 'WORKFLOW_STATE=MANAGED_OLD' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/old" --target "$tmp/target" --known-old "$tmp/known-old" --test-mode --fixture-root "$tmp")
"$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/old" --target "$tmp/target" --known-old "$tmp/known-old" --mode apply --approve --test-mode --fixture-root "$tmp" >/dev/null
cmp -s "$tmp/old" "$tmp/target"
printf 'unrelated: true\n' > "$tmp/diverged"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/diverged" --target "$tmp/target" --known-old "$tmp/known-old" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then exit 1; fi
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/old" --target "$tmp/target" --known-old "$tmp/known-old" >/dev/null 2>&1; then echo 'production accepted arbitrary known-old file' >&2; exit 1; fi
echo 'workflow-sync: PASS'

# The legacy production wrapper is a separate canonical contract. Its exact
# rendered bytes are accepted as managed-old; a one-byte change is diverged.
legacy_template="$ROOT/templates/caller/phase10-connectivity-test.yml.tpl"
current_template="$ROOT/templates/caller/codex-connectivity-test.yml.tpl"
legacy="$tmp/legacy-rendered"; current="$tmp/current-rendered"
sed -e 's#__AUTOMATION_REPOSITORY__#kusa07/codex-automation#g' -e 's#__AUTOMATION_WORKFLOW_PATH__#.github/workflows/codex-run.yml#g' -e 's#__AUTOMATION_WORKFLOW_SHA__#352857a387b1f855920fb8d1587091b31e518c21#g' -e 's#__GOOGLE_CLOUD_PROJECT_ID__#codex-automation-506111#g' -e 's#__WORKLOAD_IDENTITY_PROVIDER__#projects\/896979145485\/locations\/global\/workloadIdentityPools\/github\/providers\/github-actions#g' "$legacy_template" > "$legacy"
sed -e 's#__AUTOMATION_REPOSITORY__#kusa07/codex-automation#g' -e 's#__AUTOMATION_WORKFLOW_PATH__#.github/workflows/codex-run.yml#g' -e 's#__AUTOMATION_WORKFLOW_SHA__#80a253dd29a1e6e75f71250749f649a09e3aaba6#g' -e 's#__GOOGLE_CLOUD_PROJECT_ID__#codex-automation-506111#g' -e 's#__WORKLOAD_IDENTITY_PROVIDER__#projects\/896979145485\/locations\/global\/workloadIdentityPools\/github\/providers\/github-actions#g' -e 's#__CODEX_AUTH_SECRET_ID__#codex-auth-example-project#g' "$current_template" > "$current"
grep -q 'WORKFLOW_STATE=MANAGED_OLD' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$legacy" --target "$current" --known-old "$legacy" --test-mode --fixture-root "$tmp")
cp "$legacy" "$tmp/legacy-diverged"; printf '\n' >> "$tmp/legacy-diverged"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/legacy-diverged" --target "$current" --known-old "$legacy" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'one-byte legacy wrapper divergence was accepted' >&2; exit 1
fi
grep -q 'WORKFLOW_STATE=EXACT_TARGET' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$current" --target "$current" --test-mode --fixture-root "$tmp")
echo 'workflow-sync-canonical-templates: PASS'

# Remote interface fixture: repository ID, managed-old classification, PUT,
# and exact content/blob read-back are exercised without GitHub mutation.
remote="$(mktemp -d)"; trap 'rm -rf "$tmp" "$remote"' EXIT
mkdir -p "$remote/bin"
cat > "$remote/bin/yq" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'yq version 4.44.1';;
  -e) exit 0;;
  -r) case "$2" in
    *schema_version*) echo 1;; *repository.full_name*) echo kusa07/example-project;; *repository.id*) echo 12345;;
    *secret.id*) echo codex-auth-example-project;; *workflow.path*) echo .github/workflows/codex-connectivity-test.yml;; *workflow.branch*) echo main;; *runner.enabled*) echo true;; *runner.scope*) echo repository;;
    *) echo '';; esac;;
esac
FAKE
cat > "$remote/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == api && "$2" == repos/* && "$*" == *'@tsv'* ]]; then printf '12345\tkusa07/example-project\tmain\n'; exit 0; fi
if [[ "$1" == api ]]; then
  if [[ "$*" == *'--method PUT'* ]]; then cp "$PHASE12B_MOCK_TARGET" "$PHASE12B_MOCK_REMOTE"; echo changed > "$PHASE12B_MOCK_STATE"; exit 0; fi
  if [[ "$*" == *".content"* ]]; then base64 -w0 "$PHASE12B_MOCK_REMOTE"; exit 0; fi
  if [[ "$*" == *".sha"* ]]; then [[ "$(cat "$PHASE12B_MOCK_STATE")" == changed ]] && printf '1111111111111111111111111111111111111111\n' || printf '0123456789012345678901234567890123456789\n'; exit 0; fi
fi
FAKE
chmod +x "$remote/bin/yq" "$remote/bin/gh"
printf 'old workflow\n' > "$remote/old"; cp "$remote/old" "$remote/remote"
printf 'target workflow\n' > "$remote/template"; cp "$remote/template" "$remote/expected"
cat > "$remote/caller.yaml" <<'YAML'
schema_version: 1
repository:
  full_name: kusa07/example-project
  id: 12345
secret:
  id: codex-auth-example-project
workflow:
  path: .github/workflows/codex-connectivity-test.yml
  branch: main
runner:
  enabled: true
  scope: repository
YAML
export PATH="$remote/bin:$PATH"
export PHASE12B_CURRENT_WORKFLOW_FILE="$remote/old"
export PHASE12B_CURRENT_CONTENT_SHA=0123456789012345678901234567890123456789
export PHASE12B_CANONICAL_TEMPLATE="$remote/template"
export PHASE12B_MANAGED_OLD_WORKFLOW="$remote/old"
export PHASE12B_MOCK_TARGET="$remote/expected"
export PHASE12B_MOCK_REMOTE="$remote/remote"
export PHASE12B_REPOSITORY_ID=12345
export PHASE12B_TEST_REPOSITORY_ID=12345
export PHASE12B_TEST_DEFAULT_BRANCH=main
export PHASE12B_MOCK_STATE="$remote/state"
echo unchanged > "$PHASE12B_MOCK_STATE"
"$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --private-config "$remote/caller.yaml" --target-workflow-sha 352857a387b1f855920fb8d1587091b31e518c21 --mode plan --test-mode --fixture-root "$remote" >/dev/null
"$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --private-config "$remote/caller.yaml" --target-workflow-sha 352857a387b1f855920fb8d1587091b31e518c21 --mode apply --approve --test-mode --fixture-root "$remote" >/dev/null
cmp -s "$remote/remote" "$remote/expected"
echo 'workflow-sync-remote: PASS'
# A write/read-back branch mismatch is a safety failure, not an implicit
# fallback to a repository default.
if PHASE12B_TEST_DEFAULT_BRANCH=release "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --private-config "$remote/caller.yaml" --target-workflow-sha 352857a387b1f855920fb8d1587091b31e518c21 --mode plan --test-mode --fixture-root "$remote" >/dev/null 2>&1; then
  echo 'workflow branch mismatch was accepted' >&2; exit 1
fi
echo 'workflow-sync-branch-mismatch: PASS'
printf 'diverged workflow\n' > "$remote/diverged"
if PHASE12B_CURRENT_WORKFLOW_FILE="$remote/diverged" PHASE12B_MANAGED_OLD_WORKFLOW="$remote/not-managed" "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --private-config "$remote/caller.yaml" --target-workflow-sha 352857a387b1f855920fb8d1587091b31e518c21 --mode plan --test-mode --fixture-root "$remote" >/dev/null 2>&1; then
  echo 'remote DIVERGED state was accepted' >&2; exit 1
fi
echo 'workflow-sync-remote-diverged: PASS'
