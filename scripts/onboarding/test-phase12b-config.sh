#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "${BASH:-}" == */bash ]] || { echo 'Git Bash is required for this fixture.' >&2; exit 2; }
fixture_cli=true
run_phase12b() { local script="$1"; shift; if [[ "$fixture_cli" == true ]]; then ( source "$script" "$@" --test-mode --fixture-root "$tmp" ); else ( source "$script" "$@" ); fi; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/callers" "$tmp/retired-callers"
caller="$tmp/callers/example-project.yaml"; retired="$tmp/retired-callers/example-project.yaml"
touch "$tmp/environment.yaml" "$caller" "$tmp/host.yaml"
cat > "$tmp/bin/yq" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
--version) echo 'yq version 4.44.1';;
-e) exit 0;;
-r) case "$2" in
*schema_version*) echo 1;;
*.github.owner_id*) echo 32902649;;
*.github.owner*) echo kusa07;;
*repository.full_name*) echo kusa07/example-project;;
*repository.id*) echo 12345;;
*secret.id*) echo codex-auth-example-project;;
*active_workflow_sha*) echo 352857a387b1f855920fb8d1587091b31e518c21;;
*automation.repository*) echo kusa07/codex-automation;;
*automation.workflow_path*) echo .github/workflows/codex-run.yml;;
*google_cloud.project_id*) echo codex-automation-506111;;
*google_cloud.project_number*) echo 896979145485;;
*workload_identity_pool*) echo github;;
*workload_identity_provider_resource*) echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions;;
*workload_identity_provider*) echo github-actions;;
*workflow.path*) echo .github/workflows/codex-connectivity-test.yml;;
  *workflow.branch*) echo main;;
  *.host.config*) echo "$PHASE12B_TEST_ROOT_UNIX/host.yaml";;
  *.host_id*) echo test-host;; *.platform*) echo windows;; *.runner.mode*) echo windows-service;;
  *.runner.service_identity*) echo network-service;; *.runner.service_sid*) echo S-1-5-20;;
  *.execution.serialization*) echo global-mutex;; *.runner.labels*join*) echo self-hosted,Windows,X64,codex-automation;;
  *runner.enabled*) echo true;;
*runner.scope*) echo repository;;
*lifecycle.state*) echo retired;;
  *last_authoritative_secret_version*) sed -n 's/^[[:space:]]*last_authoritative_secret_version:[[:space:]]*//p' "$3" | tail -1;;
*) echo '';; esac;;
esac
FAKE
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == repo && "$2" == view ]]; then
  [[ "$*" == *defaultBranchRef* ]] && echo main || echo 12345
  exit 0
fi
if [[ "$1" == api ]]; then
  state="$(cat "${PHASE12B_WORKFLOW_STATE:?}")"
  if [[ "$*" == *'--include'* ]]; then [[ "$state" == absent ]] && { printf 'HTTP/1.1 404 Not Found\r\n\r\n'; exit 1; } || printf 'HTTP/1.1 200 OK\r\n\r\n';
  else printf '0123456789012345678901234567890123456789\n'; fi
fi
FAKE
cat > "$tmp/bin/yq.cmd" <<'CMD'
@echo off
if "%~1"=="--version" (
  echo yq version 4.44.1
  exit /b 0
)
if not "%~1"=="-r" exit /b 0
if "%~2"==".schema_version" echo 1
if "%~2"==".host_id" echo test-host
if "%~2"==".platform" echo windows
if "%~2"==".runner.mode" echo windows-service
if "%~2"==".runner.service_identity" echo network-service
if "%~2"==".runner.service_sid" echo S-1-5-20
if "%~2"==".paths.runner_root" echo %PHASE12B_FIXTURE_ROOT_WIN%\runners
if "%~2"==".paths.runtime_root" echo %PHASE12B_FIXTURE_ROOT_WIN%\runtime
if "%~2"==".paths.execution_root" echo %PHASE12B_FIXTURE_ROOT_WIN%\execution
if "%~2"==".paths.profile_root" echo %PHASE12B_FIXTURE_ROOT_WIN%\profile
if "%~2"==".runner.package_path" echo.
if "%~2"==".runner.labels[]" (
  echo self-hosted
  echo Windows
  echo X64
  echo codex-automation
)
if "%~2"==".execution.quiescence_timeout_seconds" echo 1
CMD
cat > "$tmp/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
member='principalSet://iam.googleapis.com/projects/896979145485/locations/global/workloadIdentityPools/github/attribute.repository_id/12345'
[[ -z "${PHASE12B_GCLOUD_CALL_LOG:-}" ]] || printf '%s\n' "$*" >> "$PHASE12B_GCLOUD_CALL_LOG"
if [[ -n "${PHASE12B_IAM_STATE:-}" ]]; then
  if [[ "$*" == *'projects describe'* ]]; then echo 896979145485; exit 0; fi
  if [[ "$*" == *'workload-identity-pools providers describe'* ]]; then echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions; exit 0; fi
  iam_mode="$(cat "$PHASE12B_IAM_STATE")"
  if [[ "$*" == *'remove-iam-policy-binding'* ]]; then [[ "$iam_mode" == fail-after || "$iam_mode" == error-after ]] && echo error-after > "$PHASE12B_IAM_STATE" || echo after > "$PHASE12B_IAM_STATE"; exit 0; fi
  if [[ "$*" == *'get-iam-policy'* ]]; then
    [[ "$iam_mode" == error-before || "$iam_mode" == error-after ]] && exit 41
    if [[ "$iam_mode" == before || "$iam_mode" == fail-after ]]; then printf 'roles/secretmanager.secretAccessor\t%s\nroles/secretmanager.secretVersionManager\t%s\n' "$member" "$member"; fi
    printf 'roles/viewer\tprincipal://unrelated\n'; exit 0
  fi
fi
state="${PHASE12B_GCLOUD_STATE:?}"
if [[ "$*" == *'secrets versions disable'* ]]; then
  [[ "$(cat "$state")" == enabled-post-error ]] && echo error > "$state" || echo zero > "$state"
  exit 0
fi
mode="$(cat "$state")"
[[ "$mode" == error ]] && exit 41
if [[ "$*" == *'secrets versions describe'* ]]; then
  requested_version="$4"; actual_version="${PHASE12B_ACTUAL_SECRET_VERSION:-$requested_version}"
  [[ "$*" == *"value(state)"* ]] && echo DISABLED || printf 'projects/1/secrets/codex-auth-example-project/versions/%s\tDISABLED\n' "$actual_version"
  exit 0
fi
if [[ "$*" == *'secrets versions list'* && "$*" == *'--filter=state=ENABLED'* ]]; then
  case "$mode" in enabled) echo projects/1/secrets/codex-auth-example-project/versions/7;; multiple) printf 'projects/1/secrets/codex-auth-example-project/versions/7\nprojects/1/secrets/codex-auth-example-project/versions/8\n';; esac
  exit 0
fi
if [[ "$*" == *'secrets versions list'* ]]; then [[ "$mode" != absent ]] || exit 55;echo '[{"name":"7","state":"ENABLED"}]'; exit 0; fi
if [[ "$*" == *'secrets list'* ]]; then [[ "$mode" != absent ]] && echo projects/1/secrets/codex-auth-example-project; exit 0; fi
if [[ "$*" == *'secrets describe'* ]]; then echo projects/1/secrets/codex-auth-example-project; exit 0; fi
if [[ "$*" == *'get-iam-policy'* ]]; then [[ "$mode" != absent ]] || exit 56;if [[ "$*" == *'--flatten='* ]]; then printf 'roles/secretmanager.secretAccessor\t%s\nroles/secretmanager.secretVersionManager\t%s\n' "$member" "$member";else echo '{"bindings":[]}';fi; exit 0; fi
FAKE
cat > "$tmp/bin/add-caller" <<'FAKE'
#!/usr/bin/env bash
echo add-caller >> "${PHASE12B_TEST_LOG:?}"
[[ "$(cat "${PHASE12B_GCLOUD_STATE:?}")" != absent ]] || echo enabled > "$PHASE12B_GCLOUD_STATE"
FAKE
cat > "$tmp/bin/hook" <<'FAKE'
#!/usr/bin/env bash
echo "${PHASE12B_HOOK_NAME:?}:$*" >> "${PHASE12B_TEST_LOG:?}"
FAKE
cat > "$tmp/bin/workflow-remove" <<'FAKE'
#!/usr/bin/env bash
echo absent > "${PHASE12B_WORKFLOW_STATE:?}"
echo "workflow-remove:$*" >> "${PHASE12B_TEST_LOG:?}"
FAKE
cat > "$tmp/bin/remove-caller" <<'FAKE'
#!/usr/bin/env bash
echo iam-revoke >> "${PHASE12B_TEST_LOG:?}"
echo after > "${PHASE12B_IAM_STATE:?}"
FAKE
cat > "$tmp/bin/auth-check" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == *'--version 9'* ]]
FAKE
cat > "$tmp/bin/auth-check-fail" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$tmp/bin/"*
export PHASE12B_TEST_ROOT_UNIX="$tmp" PHASE12B_FIXTURE_ROOT_WIN="$(cygpath -w "$tmp")"
export PATH="$tmp/bin:$PATH" PHASE12B_GCLOUD_STATE="$tmp/gcloud-state" PHASE12B_WORKFLOW_STATE="$tmp/workflow-state" PHASE12B_IAM_STATE="$tmp/iam-state"
echo enabled > "$PHASE12B_GCLOUD_STATE"
echo present > "$PHASE12B_WORKFLOW_STATE"
echo before > "$PHASE12B_IAM_STATE"

# Shell functions avoid dozens of nested Git Bash startups. They model state,
# not commands, and every lifecycle script still exercises its normal parser.
yq() {
  case "$1" in
    --version) echo 'yq version 4.44.1';;
    -e) return 0;;
    -r) case "$2" in
      *schema_version*) value="$(sed -n 's/^schema_version:[[:space:]]*//p' "$3" | head -1)";echo "${value:-1}";; *.github.owner_id*) echo 32902649;; *.github.owner*) echo kusa07;;
      *repository.full_name*) value="$(sed -n '/^repository:/,/^secret:/{s/^[[:space:]]*full_name:[[:space:]]*//p}' "$3" | head -1)";echo "${value:-kusa07/example-project}";;
      *repository.id*) value="$(sed -n '/^repository:/,/^secret:/{s/^[[:space:]]*id:[[:space:]]*//p}' "$3" | head -1)";echo "${value:-12345}";;
      *secret.id*) value="$(sed -n '/^secret:/,/^workflow:/{s/^[[:space:]]*id:[[:space:]]*//p}' "$3" | head -1)";echo "${value:-codex-auth-example-project}";;
      *active_workflow_sha*) echo 352857a387b1f855920fb8d1587091b31e518c21;; *automation.repository*) echo kusa07/codex-automation;;
      *automation.workflow_path*) echo .github/workflows/codex-run.yml;; *google_cloud.project_id*) echo codex-automation-506111;;
      *google_cloud.project_number*) echo 896979145485;; *workload_identity_pool*) echo github;;
      *workload_identity_provider_resource*) echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions;;
      *workload_identity_provider*) echo github-actions;;
      *workflow.path*) value="$(sed -n '/^workflow:/,/^lifecycle:/{s/^[[:space:]]*path:[[:space:]]*//p}' "$3" | head -1)";echo "${value:-.github/workflows/codex-connectivity-test.yml}";;
      *workflow.branch*) value="$(sed -n '/^workflow:/,/^lifecycle:/{s/^[[:space:]]*branch:[[:space:]]*//p}' "$3" | head -1)";echo "${value:-main}";; *.host.config*) echo "$tmp/host.yaml";;
      *.host_id*) echo test-host;; *.platform*) echo windows;; *.runner.mode*) echo windows-service;; *.runner.service_identity*) echo network-service;; *.runner.service_sid*) echo S-1-5-20;;
      *.execution.serialization*) echo global-mutex;; *.runner.labels*join*) echo self-hosted,Windows,X64,codex-automation;;
      *runner.enabled*) echo true;; *runner.scope*) echo repository;;
      *lifecycle.state*) sed -n 's/^[[:space:]]*state:[[:space:]]*//p' "$3" | tail -1;; *last_authoritative_secret_version*) sed -n 's/^[[:space:]]*last_authoritative_secret_version:[[:space:]]*//p' "$3" | tail -1;; *) echo '';; esac;;
  esac
}
gh() {
  if [[ "$1" == repo && "$2" == view ]]; then [[ "$*" == *defaultBranchRef* ]] && echo main || echo 12345; return 0; fi
  if [[ "$1" == api ]]; then [[ "$*" == *'--include'* ]] && printf 'HTTP/1.1 200 OK\r\n\r\n' || printf '0123456789012345678901234567890123456789\n'; fi
}
gcloud() {
  local mode member='principalSet://iam.googleapis.com/projects/896979145485/locations/global/workloadIdentityPools/github/attribute.repository_id/12345'; mode="$(<"$PHASE12B_GCLOUD_STATE")"
  [[ -z "${PHASE12B_GCLOUD_CALL_LOG:-}" ]] || printf '%s\n' "$*" >> "$PHASE12B_GCLOUD_CALL_LOG"
  if [[ "$*" == *'secrets versions disable'* ]]; then [[ "$mode" == enabled-post-error ]] && echo error > "$PHASE12B_GCLOUD_STATE" || echo zero > "$PHASE12B_GCLOUD_STATE"; return 0; fi
  [[ "$mode" == error ]] && return 41
  if [[ "$*" == *'secrets versions describe'* ]]; then local requested_version="$4" actual_version="${PHASE12B_ACTUAL_SECRET_VERSION:-$4}";[[ "$*" == *'value(state)'* ]] && echo DISABLED || printf 'projects/1/secrets/codex-auth-example-project/versions/%s\tDISABLED\n' "$actual_version"; return 0; fi
  if [[ "$*" == *'secrets versions list'* && "$*" == *'--filter=state=ENABLED'* ]]; then case "$mode" in enabled) echo projects/1/secrets/codex-auth-example-project/versions/7;; multiple) printf 'projects/1/secrets/codex-auth-example-project/versions/7\nprojects/1/secrets/codex-auth-example-project/versions/8\n';; esac; return 0; fi
  [[ "$*" == *'secrets versions list'* ]] && { [[ "$mode" != absent ]] || return 55;echo '[{"name":"7","state":"ENABLED"}]'; return 0; }
  [[ "$*" == *'secrets list'* ]] && { [[ "$mode" != absent ]] && echo projects/1/secrets/codex-auth-example-project; return 0; }
  [[ "$*" == *'secrets describe'* ]] && { echo projects/1/secrets/codex-auth-example-project; return 0; }
  [[ "$*" == *'get-iam-policy'* ]] && { [[ "$mode" != absent ]] || return 56;if [[ "$*" == *'--flatten='* ]]; then printf 'roles/secretmanager.secretAccessor\t%s\nroles/secretmanager.secretVersionManager\t%s\n' "$member" "$member";else echo '{"bindings":[]}';fi; return 0; }
}

export PHASE12B_MANAGED_AREA_WIN="$(cygpath -w "$ROOT/scripts/self-hosted/managed-execution-area.ps1")"
export PHASE12B_HOST_MODULE_WIN="$(cygpath -w "$ROOT/scripts/host/phase12b-host.psm1")"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '
  $r=$env:PHASE12B_FIXTURE_ROOT_WIN
  $runtime=Join-Path $r "runtime";$execution=Join-Path $r "execution";$profile=Join-Path $r "profile";$runners=Join-Path $r "runners"
  New-Item -ItemType Directory -Path $runtime,$profile,$runners -Force|Out-Null
  & $env:PHASE12B_MANAGED_AREA_WIN -Action ensure -Root $execution|Out-Null
  $runtimeState=[ordered]@{schema=1;host_id="test-host";service_identity="NT AUTHORITY\NETWORK SERVICE";service_sid="S-1-5-20";execution_root=$execution;runtime_root=$runtime}
  [IO.File]::WriteAllText((Join-Path $runtime "runtime.json"),($runtimeState|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  $fixture=[ordered]@{schema=1;repository_id="12345";repository_full_name="kusa07/example-project";local_present=$false;runners=@();services=@();workflow_state="PRESENT";current_run_repository_id="";mutex_state="FREE"}
  [IO.File]::WriteAllText((Join-Path $r "caller-runner-fixture.json"),($fixture|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
'
host_cli() {
  local action="$1"
  shift
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ROOT/scripts/host/caller-runner.ps1" -Action "$action" -HostConfig "$tmp/host.yaml" -RepositoryFullName kusa07/example-project -RepositoryId 12345 -TestMode -FixtureRoot "$tmp" "$@"
}
set_host_resume_state() {
  PHASE12B_RESUME_STATE="$1" powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '
    Import-Module $env:PHASE12B_HOST_MODULE_WIN -Force
    $root=$env:PHASE12B_FIXTURE_ROOT_WIN;$runtime=Join-Path $root "runtime";$runnerRoot=Join-Path $root "runners"
    $activeMetadata=Read-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName "kusa07/example-project" -RunnerRoot $runnerRoot
    $retiredMetadata=Read-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName "kusa07/example-project" -RunnerRoot $runnerRoot -State retired
    $metadata=if($null -ne $activeMetadata){$activeMetadata}else{$retiredMetadata}
    $serviceName=[string]$metadata.service_name;$fixture=Read-Phase12BCallerRunnerFixture -FixtureRoot $root
    if($env:PHASE12B_RESUME_STATE -eq "SERVICE_STOPPED"){
      foreach($service in @($fixture.services)){if($service){$service|Add-Member -NotePropertyName State -NotePropertyValue "Stopped" -Force}}
    } elseif($env:PHASE12B_RESUME_STATE -eq "RUNNER_REMOVED") {
      $fixture.services=@();$fixture.runners=@();$fixture.local_present=$false
      $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $runnerRoot -RepositoryId 12345
      if(Test-Path -LiteralPath $identity.RunnerDirectory){Remove-Item -LiteralPath $identity.RunnerDirectory -Recurse -Force}
      $retiredPath=Get-Phase12BRunnerMetadataPath -RuntimeRoot $runtime -RepositoryId 12345 -State retired
      if(Test-Path -LiteralPath $retiredPath){Remove-Item -LiteralPath $retiredPath -Force}
    } elseif($env:PHASE12B_RESUME_STATE -eq "RETIRED") {
      # Preserve the actual resources to create an intentionally contradictory
      # RETIRED fixture for the negative topology test.
    } else {throw "unsupported resume fixture"}
    Write-Phase12BCallerRunnerFixture -FixtureRoot $root -Fixture $fixture
    if($env:PHASE12B_RESUME_STATE -eq "RETIRED"){
      Write-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName "kusa07/example-project" -RunnerRoot $runnerRoot -LifecycleState RETIRED -State retired -ServiceName $serviceName|Out-Null
      $activePath=Get-Phase12BRunnerMetadataPath -RuntimeRoot $runtime -RepositoryId 12345
      if(Test-Path -LiteralPath $activePath){Remove-Item -LiteralPath $activePath -Force}
    } else {
      Write-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName "kusa07/example-project" -RunnerRoot $runnerRoot -LifecycleState $env:PHASE12B_RESUME_STATE -ServiceName $serviceName|Out-Null
    }
  '
}

out="$(run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller")"
grep -q ONBOARD_PLAN=PASS <<< "$out"
: > "$tmp/apply.log"
export PHASE12B_TEST_LOG="$tmp/apply.log"
PHASE12B_ADD_CALLER_SCRIPT="$tmp/bin/add-caller" PHASE12B_WORKFLOW_APPLY="$tmp/bin/hook" PHASE12B_VERIFY="$tmp/bin/hook" PHASE12B_HOOK_NAME=onboard run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null
grep -q '^add-caller$' "$tmp/apply.log"
[[ "$(grep -c '^onboard:' "$tmp/apply.log")" == 2 ]]

echo absent > "$PHASE12B_GCLOUD_STATE";: > "$tmp/gcloud-calls.log";export PHASE12B_GCLOUD_CALL_LOG="$tmp/gcloud-calls.log"
absent_plan="$(run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller")"
grep -q '^SECRET_ACTION=CREATE$' <<< "$absent_plan"
! grep -q 'secrets versions list\|get-iam-policy' "$tmp/gcloud-calls.log"
: > "$tmp/apply.log";PHASE12B_ADD_CALLER_SCRIPT="$tmp/bin/add-caller" PHASE12B_WORKFLOW_APPLY="$tmp/bin/hook" PHASE12B_VERIFY="$tmp/bin/hook" PHASE12B_HOOK_NAME=onboard run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null
[[ "$(cat "$PHASE12B_GCLOUD_STATE")" == enabled ]];grep -q '^add-caller$' "$tmp/apply.log";unset PHASE12B_GCLOUD_CALL_LOG
echo error > "$PHASE12B_GCLOUD_STATE";if run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" >/dev/null 2>&1; then echo 'Secret inventory permission/query failure was classified ABSENT' >&2;exit 1;fi

write_retired_record() {
  local repository_id="${1:-12345}" secret_id="${2:-codex-auth-example-project}" version="${3:-7}" state="${4:-retired}" schema="${5:-1}"
  cat > "$retired" <<YAML
schema_version: $schema
repository:
  full_name: kusa07/example-project
  id: $repository_id
secret:
  id: $secret_id
workflow:
  path: .github/workflows/codex-connectivity-test.yml
  branch: main
lifecycle:
  state: $state
  last_authoritative_secret_version: $version
YAML
}
restore_active_caller() { : > "$caller"; }

echo enabled > "$PHASE12B_GCLOUD_STATE";echo before > "$PHASE12B_IAM_STATE";echo present > "$PHASE12B_WORKFLOW_STATE"
: > "$tmp/offboard.log";: > "$tmp/gcloud-calls.log";export PHASE12B_GCLOUD_CALL_LOG="$tmp/gcloud-calls.log"
export PHASE12B_WORKFLOW_REMOVE="$tmp/bin/workflow-remove" PHASE12B_STATE_RETIRE="$tmp/bin/hook" PHASE12B_VERIFY="$tmp/bin/hook" PHASE12B_REMOVE_CALLER_SCRIPT="$tmp/bin/remove-caller" PHASE12B_HOOK_NAME=offboard PHASE12B_TEST_LOG="$tmp/offboard.log"
rm -f -- "$retired"
run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null
[[ ! -e "$caller" && -f "$retired" ]];grep -q 'last_authoritative_secret_version: 7' "$retired"
[[ "$(cat "$PHASE12B_GCLOUD_STATE")" == zero && "$(cat "$PHASE12B_IAM_STATE")" == after && "$(cat "$PHASE12B_WORKFLOW_STATE")" == absent ]]
host_cli Inspect | grep -q '^CALLER_RUNNER_LIFECYCLE_STATE_AFTER=RETIRED$'

# Completed production-parity rerun: do not restore the active caller file.
provider_log_before="$(sha256sum "$tmp/offboard.log")";retired_hash_before="$(sha256sum "$retired")"
fixture_hash_before="$(sha256sum "$tmp/caller-runner-fixture.json")";runtime_hash_before="$(find "$tmp/runtime" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
secret_mutations_before="$(grep -c 'secrets versions disable' "$tmp/gcloud-calls.log" || true)"
noop_output="$(run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve)"
grep -q '^POSTCONDITION=RETIRED_VERIFIED$' <<< "$noop_output";grep -q '^MUTATIONS_PERFORMED=NONE$' <<< "$noop_output"
[[ ! -e "$caller" && "$provider_log_before" == "$(sha256sum "$tmp/offboard.log")" && "$retired_hash_before" == "$(sha256sum "$retired")" ]]
[[ "$fixture_hash_before" == "$(sha256sum "$tmp/caller-runner-fixture.json")" && "$runtime_hash_before" == "$(find "$tmp/runtime" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" ]]
[[ "$secret_mutations_before" == "$(grep -c 'secrets versions disable' "$tmp/gcloud-calls.log" || true)" ]]

# Outer shell resume must select the canonical downstream stage rather than
# replay BeginRetirement. These fixtures use the same caller deletion logic.
for resume_state in SERVICE_STOPPED RUNNER_REMOVED; do
  restore_active_caller;rm -f -- "$retired";echo enabled > "$PHASE12B_GCLOUD_STATE";echo before > "$PHASE12B_IAM_STATE";echo absent > "$PHASE12B_WORKFLOW_STATE"
  host_cli Onboard >/dev/null;set_host_resume_state "$resume_state"
  resume_output="$(run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve)"
  grep -q '^OFFBOARD_APPLY=PASS$' <<< "$resume_output";[[ ! -e "$caller" ]]
  host_cli Inspect | grep -q '^CALLER_RUNNER_LIFECYCLE_STATE_AFTER=RETIRED$'
done

# Secret-disabled and IAM-already-removed resume skips both mutations.
restore_active_caller;rm -f -- "$retired";host_cli Onboard >/dev/null;set_host_resume_state RUNNER_REMOVED
write_retired_record 12345 codex-auth-example-project 7 retiring;echo zero > "$PHASE12B_GCLOUD_STATE";echo after > "$PHASE12B_IAM_STATE";echo absent > "$PHASE12B_WORKFLOW_STATE"
iam_mutations_before="$(grep -c '^iam-revoke$' "$tmp/offboard.log" || true)";secret_mutations_before="$(grep -c 'secrets versions disable' "$tmp/gcloud-calls.log" || true)"
run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null
[[ ! -e "$caller" && "$iam_mutations_before" == "$(grep -c '^iam-revoke$' "$tmp/offboard.log" || true)" && "$secret_mutations_before" == "$(grep -c 'secrets versions disable' "$tmp/gcloud-calls.log" || true)" ]]

# RETIRED negative matrix and finalization-only boundary.
mv -- "$retired" "$tmp/retired.saved"
if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1; then echo 'active/retired absence was accepted' >&2;exit 1;fi
mv -- "$tmp/retired.saved" "$retired"
cp -- "$retired" "$tmp/retired.good"
write_retired_record 999 codex-auth-example-project 7 retired;if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'retired repository mismatch accepted' >&2;exit 1;fi
write_retired_record 12345 wrong-secret 7 retired;if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'retired Secret mismatch accepted' >&2;exit 1;fi
cp -- "$tmp/retired.good" "$retired"
if PHASE12B_ACTUAL_SECRET_VERSION=8 run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'retired authoritative version mismatch accepted' >&2;exit 1;fi
write_retired_record 12345 codex-auth-example-project 7 retired 99;if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'retired schema mismatch accepted' >&2;exit 1;fi
cp -- "$tmp/retired.good" "$retired"
host_cli Onboard >/dev/null
set_host_resume_state RUNNER_REMOVED
finalize_plan="$(run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller")"
grep -q '^POSTCONDITION=RETIRED_FINALIZATION_READY$' <<< "$finalize_plan";! grep -q '^POSTCONDITION=RETIRED_VERIFIED$' <<< "$finalize_plan"
finalize_only="$(run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve)"
grep -q '^MUTATIONS_PERFORMED=LOCAL_METADATA_FINALIZATION$' <<< "$finalize_only"
echo enabled > "$PHASE12B_GCLOUD_STATE";if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'RETIRED enabled Secret accepted' >&2;exit 1;fi;echo zero > "$PHASE12B_GCLOUD_STATE"
echo before > "$PHASE12B_IAM_STATE";if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'RETIRED IAM binding accepted' >&2;exit 1;fi;echo after > "$PHASE12B_IAM_STATE"
host_cli Onboard >/dev/null;set_host_resume_state RETIRED
if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'RETIRED runner/service contradiction accepted' >&2;exit 1;fi
set_host_resume_state RUNNER_REMOVED;host_cli Offboard -FinalizeRetirement >/dev/null
echo present > "$PHASE12B_WORKFLOW_STATE";if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'RETIRED workflow accepted' >&2;exit 1;fi;echo absent > "$PHASE12B_WORKFLOW_STATE"
echo error > "$PHASE12B_GCLOUD_STATE";if run_phase12b "$ROOT/scripts/onboarding/offboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve >/dev/null 2>&1;then echo 'RETIRED read-back error accepted' >&2;exit 1;fi;echo zero > "$PHASE12B_GCLOUD_STATE"
unset PHASE12B_GCLOUD_CALL_LOG

cat > "$tmp/retired-reonboard.yaml" <<'YAML'
schema_version: 1
repository:
  full_name: kusa07/example-project
  id: 12345
secret:
  id: codex-auth-example-project
workflow:
  path: .github/workflows/codex-connectivity-test.yml
  branch: main
lifecycle:
  state: retired
  last_authoritative_secret_version: 9
YAML
echo zero > "$PHASE12B_GCLOUD_STATE"
restore_active_caller
reonboard_out="$(PHASE12B_REONBOARD_AUTH_CHECK="$tmp/bin/auth-check" run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --retired-caller "$tmp/retired-reonboard.yaml")"
grep -q REONBOARD_STATE=RESTORE_CANDIDATE <<< "$reonboard_out"
reonboard_invalid="$(PHASE12B_REONBOARD_AUTH_CHECK="$tmp/bin/auth-check-fail" run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --retired-caller "$tmp/retired-reonboard.yaml")"
grep -q REONBOARD_STATE=STOP <<< "$reonboard_invalid"
if PHASE12B_REONBOARD_VERSION_ID=8 PHASE12B_REONBOARD_AUTH_CHECK="$tmp/bin/auth-check" run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --retired-caller "$tmp/retired-reonboard.yaml" >/dev/null 2>&1; then echo 'environment version overrode retired metadata' >&2; exit 1; fi
if PHASE12B_REONBOARD_VERSION_ID=9 PHASE12B_REONBOARD_AUTH_CHECK="$tmp/bin/auth-check" run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --retired-caller "$tmp/retired-reonboard.yaml" >/dev/null 2>&1; then echo 'environment version was accepted as re-onboard authority' >&2; exit 1; fi
if (fixture_cli=false; PHASE12B_REONBOARD_AUTH_CHECK="$tmp/bin/auth-check" run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --retired-caller "$tmp/retired-reonboard.yaml" >/dev/null 2>&1); then echo 'production path accepted an environment-injected auth validator' >&2; exit 1; fi
if (fixture_cli=false; PHASE12B_TEST_MODE=1 run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" >/dev/null 2>&1); then echo 'environment-based test activation was accepted' >&2; exit 1; fi
if (fixture_cli=false; PHASE12B_INTERNAL_TEST_MODE=1 PHASE12B_INTERNAL_TEST_ROOT="$tmp" run_phase12b "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" >/dev/null 2>&1); then echo 'internal environment test activation was accepted' >&2; exit 1; fi
grep -q 'secrets versions access' "$ROOT/scripts/onboarding/onboard-caller.sh"
grep -q 'codex login status' "$ROOT/scripts/onboarding/onboard-caller.sh"
if sed -n '/elif ! phase12b_test_mode/,/fi/p' "$ROOT/scripts/onboarding/onboard-caller.sh" | grep -q 'auth_valid=true'; then echo 'production metadata-only authentication validity remains' >&2; exit 1; fi

export PHASE12B_IAM_STATE="$tmp/iam-state"
echo before > "$PHASE12B_IAM_STATE"
"$ROOT/scripts/google-cloud/remove-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve --test-mode --fixture-root "$tmp" >/dev/null
[[ "$(cat "$PHASE12B_IAM_STATE")" == after ]] || { echo 'IAM fixture did not reach read-back state' >&2; exit 1; }
echo error-before > "$PHASE12B_IAM_STATE"
if "$ROOT/scripts/google-cloud/remove-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then echo 'IAM pre-mutation query error was accepted as empty' >&2; exit 1; fi
echo fail-after > "$PHASE12B_IAM_STATE"
if "$ROOT/scripts/google-cloud/remove-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" --mode apply --approve --test-mode --fixture-root "$tmp" >/dev/null 2>&1; then echo 'IAM post-mutation query error was accepted' >&2; exit 1; fi
if PHASE12B_IAM_REVOKE='echo injected' "$ROOT/scripts/google-cloud/remove-caller.sh" --environment "$tmp/environment.yaml" --caller "$caller" >/dev/null 2>&1; then echo 'production IAM command injection was accepted' >&2; exit 1; fi
! grep -q 'bash -c' "$ROOT/scripts/google-cloud/remove-caller.sh"
unset PHASE12B_IAM_STATE

! grep -q NOT_IMPLEMENTED_BATCH_A "$ROOT/scripts/onboarding/onboard-caller.sh"
! grep -q NOT_IMPLEMENTED_BATCH_A "$ROOT/scripts/onboarding/offboard-caller.sh"
grep -q AUTHORITATIVE_VERSION_ID "$ROOT/scripts/onboarding/offboard-caller.sh"
echo 'config: PASS'
