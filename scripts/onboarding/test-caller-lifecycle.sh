#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/phase12b-config.sh"
[[ "$(phase12b_classify_caller_lifecycle '' '' 12345)" == NEW ]]
[[ "$(phase12b_classify_caller_lifecycle 12345 '' 12345)" == ACTIVE_MATCH ]]
[[ "$(phase12b_classify_caller_lifecycle '' 12345 12345)" == RETIRED_MATCH ]]
[[ "$(phase12b_classify_caller_lifecycle 999 '' 12345)" == IDENTITY_CONFLICT ]]
[[ "$(phase12b_classify_caller_lifecycle 12345 12345 12345)" == IDENTITY_CONFLICT ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 true DISABLED true 0)" == RESTORE_CANDIDATE ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 false DISABLED true 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 999 codex-auth-example codex-auth-example 9 true DISABLED true 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example wrong-secret 9 true DISABLED true 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example latest true DISABLED true 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 true ENABLED true 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 true DISABLED false 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 true DISABLED true 2)" == STOP ]]
gh_status_fixture() { printf 'HTTP/1.1 %s fixture\r\n\r\n' "$PHASE12B_TEST_HTTP_STATUS"; [[ "$PHASE12B_TEST_HTTP_STATUS" == 200 ]]; }
PHASE12B_TEST_HTTP_STATUS=200;[[ "$(phase12b_github_content_state gh_status_fixture endpoint)" == PRESENT ]]
PHASE12B_TEST_HTTP_STATUS=404;[[ "$(phase12b_github_content_state gh_status_fixture endpoint)" == ABSENT ]]
for PHASE12B_TEST_HTTP_STATUS in 401 403 500; do if phase12b_github_content_state gh_status_fixture endpoint >/dev/null 2>&1; then echo "HTTP $PHASE12B_TEST_HTTP_STATUS was accepted as absent" >&2; exit 1; fi; done
gh_network_fixture() { echo network-error >&2; return 7; }
if phase12b_github_content_state gh_network_fixture endpoint >/dev/null 2>&1; then echo 'network error was accepted as absent' >&2; exit 1; fi
gh_malformed_fixture() { echo malformed; return 0; }
if phase12b_github_content_state gh_malformed_fixture endpoint >/dev/null 2>&1; then echo 'malformed response was accepted as absent' >&2; exit 1; fi
iam_member='principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/pool/attribute.repository_id/123'
iam_exact=$(printf 'roles/secretmanager.secretAccessor\t%s\nroles/secretmanager.secretVersionManager\t%s\n' "$iam_member" "$iam_member")
phase12b_secret_iam_exact "$iam_exact" "$iam_member"
iam_extra="$iam_exact"$'\nroles/secretmanager.secretAccessor\tprincipal://unexpected'
if phase12b_secret_iam_exact "$iam_extra" "$iam_member"; then echo 'extra IAM member was accepted' >&2; exit 1; fi
# Guard against the previous plan-only stubs returning a false implementation
# success.  Apply paths must have an executable success contract and a real
# orchestration hook, even though this test never invokes external mutation.
! grep -q 'NOT_IMPLEMENTED_BATCH_A' "$ROOT/scripts/onboarding/onboard-caller.sh"
! grep -q 'NOT_IMPLEMENTED_BATCH_A' "$ROOT/scripts/onboarding/offboard-caller.sh"
grep -q 'ONBOARD_APPLY=PASS' "$ROOT/scripts/onboarding/onboard-caller.sh"
grep -q 'OFFBOARD_APPLY=PASS' "$ROOT/scripts/onboarding/offboard-caller.sh"
grep -q 'phase12b_caller_runner Onboard' "$ROOT/scripts/onboarding/onboard-caller.sh"
grep -q 'phase12b_caller_runner Offboard' "$ROOT/scripts/onboarding/offboard-caller.sh"
grep -q 'Environment-based test activation is prohibited' "$ROOT/scripts/onboarding/onboard-caller.sh"
echo 'lifecycle: PASS'
