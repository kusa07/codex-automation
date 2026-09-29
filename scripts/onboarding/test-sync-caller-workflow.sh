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

# Historical pre-no-PR-return canonical bytes are an explicit repository-owned
# compatibility authority.  They are accepted only when compared byte-for-byte
# against the rendered approved-SHA candidate; similar or unapproved content
# remains DIVERGED.
historical_template="$ROOT/templates/caller/codex-connectivity-test-pre-no-pr-return.yml.tpl"
historical="$tmp/historical-rendered"; historical_unapproved="$tmp/historical-unapproved"
historical_blob_sha="$(git -C "$ROOT" rev-parse HEAD:templates/caller/codex-connectivity-test-pre-no-pr-return.yml.tpl)"
[[ "$historical_blob_sha" == 22dacc79bb6a9fb7225f5da33506097180f546aa ]] || { echo 'Historical canonical blob hash changed.' >&2; exit 1; }
[[ "$(git -C "$ROOT" check-attr eol -- templates/caller/codex-connectivity-test-pre-no-pr-return.yml.tpl | awk '{print $3}')" == lf ]] || { echo 'Historical canonical template must use LF checkout filtering.' >&2; exit 1; }
git -C "$ROOT" show HEAD:templates/caller/codex-connectivity-test-pre-no-pr-return.yml.tpl | git hash-object --stdin | grep -qx 22dacc79bb6a9fb7225f5da33506097180f546aa || { echo 'Historical canonical blob bytes changed.' >&2; exit 1; }
filtered_blob_sha="$(git -C "$ROOT" -c core.autocrlf=true cat-file --filters --path=templates/caller/codex-connectivity-test-pre-no-pr-return.yml.tpl HEAD:templates/caller/codex-connectivity-test-pre-no-pr-return.yml.tpl | git hash-object --stdin)"
[[ "$filtered_blob_sha" == 22dacc79bb6a9fb7225f5da33506097180f546aa ]] || { echo 'Windows-filtered historical canonical bytes changed.' >&2; exit 1; }
sed -e 's#__AUTOMATION_REPOSITORY__#kusa07/codex-automation#g' -e 's#__AUTOMATION_WORKFLOW_PATH__#.github/workflows/codex-run.yml#g' -e 's#__AUTOMATION_WORKFLOW_SHA__#352857a387b1f855920fb8d1587091b31e518c21#g' -e 's#__GOOGLE_CLOUD_PROJECT_ID__#codex-automation-506111#g' -e 's#__WORKLOAD_IDENTITY_PROVIDER__#projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions#g' -e 's#__CODEX_AUTH_SECRET_ID__#codex-auth-example-project#g' "$historical_template" > "$historical"
grep -q 'WORKFLOW_STATE=MANAGED_OLD' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$historical" --target "$current" --known-old "$historical" --test-mode --fixture-root "$tmp")
sed 's/issues: read/issues: writ3/' "$historical" > "$tmp/historical-one-byte"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/historical-one-byte" --target "$current" --known-old "$historical" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'one-byte historical canonical divergence was accepted' >&2; exit 1
fi
sed -e 's/352857a387b1f855920fb8d1587091b31e518c21/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$historical" > "$historical_unapproved"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$historical_unapproved" --target "$current" --known-old "$historical" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'unapproved historical SHA was accepted' >&2; exit 1
fi
sed 's/issues: read/issues: write/' "$historical" > "$tmp/historical-issues-only"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/historical-issues-only" --target "$current" --known-old "$historical" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'issues-only historical variation was accepted' >&2; exit 1
fi
printf 'uses: example@%040d\n' 9 > "$tmp/arbitrary-sha-match"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/arbitrary-sha-match" --target "$current" --known-old "$historical" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'arbitrary workflow matching SHA was accepted' >&2; exit 1
fi
echo 'workflow-sync-historical-canonical: PASS'

# The immediate predecessor to actions:read is a separate byte-exact authority.
# Its Git blob must remain identical to the formerly canonical template on
# Windows checkouts, and only an approved immutable workflow SHA may migrate.
previous_template="$ROOT/templates/caller/codex-connectivity-test-pre-actions-read.yml.tpl"
previous="$tmp/previous-rendered"
[[ "$(git -C "$ROOT" hash-object "$previous_template")" == e66ea0a2ada71cffb6a88ac2467c37b600f9829b ]] || { echo 'Immediate-previous canonical blob hash changed.' >&2; exit 1; }
[[ "$(git -C "$ROOT" check-attr eol -- templates/caller/codex-connectivity-test-pre-actions-read.yml.tpl | awk '{print $3}')" == lf ]] || { echo 'Immediate-previous canonical template must use LF checkout filtering.' >&2; exit 1; }
sed -e 's#__AUTOMATION_REPOSITORY__#kusa07/codex-automation#g' -e 's#__AUTOMATION_WORKFLOW_PATH__#.github/workflows/codex-run.yml#g' -e 's#__AUTOMATION_WORKFLOW_SHA__#352857a387b1f855920fb8d1587091b31e518c21#g' -e 's#__GOOGLE_CLOUD_PROJECT_ID__#codex-automation-506111#g' -e 's#__WORKLOAD_IDENTITY_PROVIDER__#projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions#g' -e 's#__CODEX_AUTH_SECRET_ID__#codex-auth-example-project#g' "$previous_template" > "$previous"
grep -q 'WORKFLOW_STATE=MANAGED_OLD' < <("$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$previous" --target "$current" --known-old "$previous" --test-mode --fixture-root "$tmp")
sed 's/issues: write/issues: writ3/' "$previous" > "$tmp/previous-one-byte"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/previous-one-byte" --target "$current" --known-old "$previous" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'one-byte immediate-previous divergence was accepted' >&2; exit 1
fi
sed 's/352857a387b1f855920fb8d1587091b31e518c21/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$previous" > "$tmp/previous-unapproved"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --existing "$tmp/previous-unapproved" --target "$current" --known-old "$previous" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then
  echo 'unapproved immediate-previous SHA was accepted' >&2; exit 1
fi
echo 'workflow-sync-immediate-previous: PASS'

# Production-shaped authority fixture: no --test-mode and no --known-old are
# permitted here.  The mocked gh/gcloud/yq commands stand in only for external
# read-back while the production branch generates candidates from the approved
# WIF SHA set and repository-owned templates.
prod="$(mktemp -d)"; remote=''; trap 'rm -rf "$tmp" "${remote:-}" "$prod"' EXIT
mkdir -p "$prod/bin"
cat > "$prod/bin/yq" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'yq version v4.53.6'; exit 0; }
[[ "${1:-}" == -e ]] && exit 0
query="${2:-}"
case "$query" in
  *schema_version*) echo 1;;
  *.github.owner\ * ) echo kusa07;;
  *.github.owner_id\ * ) echo 123;;
  *.google_cloud.project_id\ * ) echo test-project-12345;;
  *.google_cloud.project_number\ * ) echo 896979145485;;
  *.google_cloud.workload_identity_pool\ * ) echo github;;
  *.google_cloud.workload_identity_provider\ * ) echo github-actions;;
  *.google_cloud.workload_identity_provider_resource\ * ) echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions;;
  *.automation.repository\ * ) echo kusa07/codex-automation;;
  *.automation.workflow_path\ * ) echo .github/workflows/codex-run.yml;;
  *.automation.active_workflow_sha\ * ) echo eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;;
  *.repository.full_name\ * ) echo kusa07/example-project;;
  *.repository.id\ * ) echo 12345;;
  *.secret.id\ * ) echo codex-auth-example-project;;
  *.workflow.path\ * ) echo .github/workflows/codex-connectivity-test.yml;;
  *.workflow.branch\ * ) echo main;;
  *.runner.enabled\ * ) echo true;;
  *.runner.scope\ * ) echo repository;;
  *) echo '';;
esac
FAKE
cat > "$prod/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == *'@tsv'* ]]; then printf '12345\tkusa07/example-project\tmain\n'; exit 0; fi
if [[ "$*" == *'--include'* ]]; then printf 'HTTP/2 200 OK\r\n\r\n'; exit 0; fi
if [[ "$*" == *'.sha'* ]]; then printf '0123456789012345678901234567890123456789\n'; exit 0; fi
if [[ "$*" == *'.content'* ]]; then base64 -w0 "$MOCK_REMOTE"; exit 0; fi
exit 1
FAKE
cat > "$prod/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == *attributeCondition* ]]; then printf "assertion.repository_owner_id == '123' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21','8d94535fedb5252aeecfacff3f0be7c8dcdba947','eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee']\n"; exit 0; fi
exit 1
FAKE
chmod +x "$prod/bin/yq" "$prod/bin/gh" "$prod/bin/gcloud"
printf 'schema_version: 1\n' > "$prod/environment.yaml"
printf 'schema_version: 1\n' > "$prod/caller.yaml"
sed -e 's#__AUTOMATION_REPOSITORY__#kusa07/codex-automation#g' -e 's#__AUTOMATION_WORKFLOW_PATH__#.github/workflows/codex-run.yml#g' -e 's#__AUTOMATION_WORKFLOW_SHA__#352857a387b1f855920fb8d1587091b31e518c21#g' -e 's#__GOOGLE_CLOUD_PROJECT_ID__#test-project-12345#g' -e 's#__WORKLOAD_IDENTITY_PROVIDER__#projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions#g' -e 's#__CODEX_AUTH_SECRET_ID__#codex-auth-example-project#g' "$historical_template" > "$prod/historical"
export PATH="$prod/bin:$PATH" MOCK_REMOTE="$prod/historical"
unset PHASE12B_GH_BIN PHASE12B_TEST_REPOSITORY_ID PHASE12B_TEST_DEFAULT_BRANCH PHASE12B_CURRENT_WORKFLOW_FILE PHASE12B_CURRENT_CONTENT_SHA PHASE12B_CANONICAL_TEMPLATE PHASE12B_MANAGED_OLD_WORKFLOW PHASE12B_AUTOMATION_REPOSITORY PHASE12B_AUTOMATION_WORKFLOW_PATH
if ! "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --environment "$prod/environment.yaml" --private-config "$prod/caller.yaml" --target-workflow-sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --mode plan > "$prod/exact.out"; then
  echo 'production-shaped historical canonical was not accepted' >&2; exit 1
fi
grep -q 'WORKFLOW_STATE=MANAGED_OLD' "$prod/exact.out"
sed 's/issues: read/issues: writ3/' "$prod/historical" > "$prod/mutated"
export MOCK_REMOTE="$prod/mutated"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --environment "$prod/environment.yaml" --private-config "$prod/caller.yaml" --target-workflow-sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --mode plan > "$prod/mutated.out" 2>&1; then
  echo 'production-shaped one-byte divergence was accepted' >&2; exit 1
fi
sed -e 's/352857a387b1f855920fb8d1587091b31e518c21/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$prod/historical" > "$prod/unapproved"
export MOCK_REMOTE="$prod/unapproved"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --environment "$prod/environment.yaml" --private-config "$prod/caller.yaml" --target-workflow-sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --mode plan > "$prod/unapproved.out" 2>&1; then
  echo 'production-shaped unapproved SHA was accepted' >&2; exit 1
fi
sed -e 's#__AUTOMATION_REPOSITORY__#kusa07/codex-automation#g' -e 's#__AUTOMATION_WORKFLOW_PATH__#.github/workflows/codex-run.yml#g' -e 's#__AUTOMATION_WORKFLOW_SHA__#8d94535fedb5252aeecfacff3f0be7c8dcdba947#g' -e 's#__GOOGLE_CLOUD_PROJECT_ID__#test-project-12345#g' -e 's#__WORKLOAD_IDENTITY_PROVIDER__#projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions#g' -e 's#__CODEX_AUTH_SECRET_ID__#codex-auth-example-project#g' "$previous_template" > "$prod/previous"
export MOCK_REMOTE="$prod/previous"
if ! "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --environment "$prod/environment.yaml" --private-config "$prod/caller.yaml" --target-workflow-sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --mode plan > "$prod/previous.out"; then
  echo 'production-shaped immediate-previous canonical was not accepted' >&2; exit 1
fi
grep -q 'WORKFLOW_STATE=MANAGED_OLD' "$prod/previous.out"
sed 's/issues: write/issues: writ3/' "$prod/previous" > "$prod/previous-mutated"
export MOCK_REMOTE="$prod/previous-mutated"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --environment "$prod/environment.yaml" --private-config "$prod/caller.yaml" --target-workflow-sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --mode plan > "$prod/previous-mutated.out" 2>&1; then
  echo 'production-shaped immediate-previous one-byte divergence was accepted' >&2; exit 1
fi
sed 's/8d94535fedb5252aeecfacff3f0be7c8dcdba947/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$prod/previous" > "$prod/previous-unapproved"
export MOCK_REMOTE="$prod/previous-unapproved"
if "$ROOT/scripts/onboarding/sync-caller-workflow.sh" --repository kusa07/example-project --environment "$prod/environment.yaml" --private-config "$prod/caller.yaml" --target-workflow-sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee --mode plan > "$prod/previous-unapproved.out" 2>&1; then
  echo 'production-shaped immediate-previous unapproved SHA was accepted' >&2; exit 1
fi
echo 'workflow-sync-production-historical: PASS'

# Remote interface fixture: repository ID, managed-old classification, PUT,
# and exact content/blob read-back are exercised without GitHub mutation.
remote="$(mktemp -d)"; trap 'rm -rf "$tmp" "$remote" "$prod"' EXIT
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
