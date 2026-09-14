#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/phase12b-config.sh"
[[ "$(phase12b_classify_caller_lifecycle '' '' 12345)" == NEW ]]
[[ "$(phase12b_classify_caller_lifecycle 12345 '' 12345)" == ACTIVE_MATCH ]]
[[ "$(phase12b_classify_caller_lifecycle '' 12345 12345)" == RETIRED_MATCH ]]
[[ "$(phase12b_classify_caller_lifecycle 999 '' 12345)" == IDENTITY_CONFLICT ]]
[[ "$(phase12b_classify_caller_lifecycle 12345 12345 12345)" == IDENTITY_CONFLICT ]]
echo 'lifecycle: PASS'
