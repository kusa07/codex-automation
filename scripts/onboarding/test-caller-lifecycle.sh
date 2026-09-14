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
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 true DISABLED false 0)" == STOP ]]
[[ "$(phase12b_classify_reonboard 12345 12345 codex-auth-example codex-auth-example 9 true DISABLED true 2)" == STOP ]]
echo 'lifecycle: PASS'
