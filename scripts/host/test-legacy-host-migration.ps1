$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force

function Assert-Equal($Actual,$Expected,[string]$Message){if([string]$Actual -cne [string]$Expected){throw "$Message (actual=$Actual expected=$Expected)"}}
function Assert-Throws([scriptblock]$Action,[string]$Message){try{& $Action;throw "$Message unexpectedly succeeded"}catch{if($_.Exception.Message -eq "$Message unexpectedly succeeded"){throw}}}
function Copy-Object($Value){$Value|ConvertTo-Json -Depth 20|ConvertFrom-Json}

$root=Join-Path ([IO.Path]::GetTempPath()) ('phase12b-migration-'+[guid]::NewGuid().ToString('N'))
try{
  New-Item -ItemType Directory -Path $root|Out-Null

  # StrictMode must preserve the explicit TestMode boundary for zero, one, and many paths.
  Test-Phase12BTestAdapter
  Assert-Throws {Test-Phase12BTestAdapter -AdapterLog (Join-Path $root 'adapter.log')} 'production adapter path'
  Test-Phase12BTestAdapter -TestMode -FixtureRoot $root -AdapterLog (Join-Path $root 'adapter.log')
  Test-Phase12BTestAdapter -TestMode -FixtureRoot $root -AdapterLog (Join-Path $root 'adapter.log') -MigrationReadbackFile (Join-Path $root 'migration.json')
  Assert-Throws {Test-Phase12BTestAdapter -TestMode -FixtureRoot $root -MigrationReadbackFile (Join-Path ([IO.Path]::GetTempPath()) 'outside-migration.json')} 'fixture path escape'
  $env:PHASE12B_TEST_ADAPTER='1';Assert-Throws {Test-Phase12BTestAdapter} 'environment adapter';Remove-Item Env:PHASE12B_TEST_ADAPTER

  $base=[pscustomobject]@{
    HostState='INCONSISTENT';CurrentManagedExact=$false;IdentityConflict=$false;DuplicateGitHubRunner=$false;UnexpectedService=$false;RepositoryMismatch=$false;RunnerNameMismatch=$false;RunnerIdMismatch=$false
    ExecutionRootPresent=$true;ExecutionInspect=$true;ExecutionPreflight=$true;ExecutionAreaIdExact=$true;CurrentRunState='ABSENT';MutexState='FREE';ResidualClean=$true;CredentialResidue=$false;RelevantProcessCount=0
    LegacyRunnerPresent=$true;LegacyRunnerSafe=$true;LegacyRunnerFilesExact=$true;LocalRunnerMetadataExact=$true;GitHubRunnerCount=1;GitHubRunnerExact=$true;GitHubRunnerStatus='offline';GitHubRunnerBusy=$false;ActiveGitHubJobCount=0
    LegacyServicePresent=$false;RunnerProcessCount=0;TargetRootsAbsent=$true;WorkflowState='MANAGED_OLD';DispatchInitiallyActive=$true
  }
  Assert-Equal (Get-Phase12BMigrationSourceState $base) LEGACY_PHASE10_INTERACTIVE 'exact legacy fingerprint'
  $managed=Copy-Object $base;$managed.HostState='EXISTING';$managed.CurrentManagedExact=$true
  Assert-Equal (Get-Phase12BMigrationSourceState $managed) CURRENT_MANAGED 'current managed classification'
  foreach($field in @('ExecutionRootPresent','ExecutionInspect','ExecutionPreflight','ExecutionAreaIdExact','ResidualClean','LegacyRunnerSafe','LegacyRunnerFilesExact','LocalRunnerMetadataExact','GitHubRunnerExact','TargetRootsAbsent')){$bad=Copy-Object $base;$bad.$field=$false;Assert-Equal (Get-Phase12BMigrationSourceState $bad) UNSUPPORTED_PARTIAL "partial $field"}
  $disabled=Copy-Object $base;$disabled.DispatchInitiallyActive=$false;Assert-Equal (Get-Phase12BMigrationSourceState $disabled) UNSUPPORTED_PARTIAL 'pre-disabled workflow'
  foreach($field in @('IdentityConflict','DuplicateGitHubRunner','UnexpectedService','RepositoryMismatch','RunnerNameMismatch','RunnerIdMismatch')){$bad=Copy-Object $base;$bad.$field=$true;Assert-Equal (Get-Phase12BMigrationSourceState $bad) CONFLICT "conflict $field"}
  foreach($pair in @(@('CurrentRunState','VALID'),@('MutexState','BUSY'),@('RelevantProcessCount',1),@('RunnerProcessCount',1),@('ActiveGitHubJobCount',1),@('WorkflowState','DIVERGED'))){$bad=Copy-Object $base;$bad.($pair[0])=$pair[1];Assert-Equal (Get-Phase12BMigrationSourceState $bad) UNSUPPORTED_PARTIAL "unsafe $($pair[0])"}
  $credential=Copy-Object $base;$credential.CredentialResidue=$true;Assert-Equal (Get-Phase12BMigrationSourceState $credential) UNSUPPORTED_PARTIAL 'credential residue'
  $online=Copy-Object $base;$online.GitHubRunnerStatus='online';Assert-Equal (Get-Phase12BMigrationSourceState $online) UNSUPPORTED_PARTIAL 'legacy runner online'

  $identity=[pscustomobject]@{RepositoryId='1338414331';RepositoryFullName='kusa07/interest-gacha';LegacyRunnerDirectory='C:\codex-runner';LegacyRunnerId='21';LegacyRunnerName='codex-automation-windows-01';ExecutionAreaId='545b497b-f7f6-4d44-90e3-544afa1bab4f';TargetRunnerDirectory='C:\codex-runners\repo-1338414331';TargetRunnerName='codex-repo-1338414331'}
  $runtime=Join-Path $root 'runtime'
  $written=Initialize-Phase12BMigrationIntent -RuntimeRoot $runtime -Identity $identity
  if(-not(Test-Phase12BMigrationIntent $written)){throw 'valid migration intent rejected'}
  $read=Read-Phase12BMigrationIntent -RuntimeRoot $runtime;Assert-Equal $read.migration_stage LEGACY_VERIFIED 'intent round-trip'
  Assert-Throws {Initialize-Phase12BMigrationIntent -RuntimeRoot $runtime -Identity $identity} 'duplicate initial intent'
  Write-Phase12BMigrationIntent -RuntimeRoot $runtime -Stage DISPATCH_FENCED -Identity $identity|Out-Null
  Assert-Equal (Read-Phase12BMigrationIntent $runtime).migration_stage DISPATCH_FENCED 'atomic intent update'

  $package=Get-Phase12BRunnerPackageContract
  Assert-Equal $package.Version 2.337.0 'package version'
  Assert-Equal $package.ArchiveName actions-runner-win-x64-2.337.0.zip 'package archive'
  Assert-Equal $package.Uri 'https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-win-x64-2.337.0.zip' 'package source'
  Assert-Equal $package.Sha256 '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc' 'package digest'
  $digestFile=Join-Path $root 'digest.bin';[IO.File]::WriteAllText($digestFile,'phase12b',[Text.UTF8Encoding]::new($false));$digest=(Get-FileHash $digestFile -Algorithm SHA256).Hash.ToLowerInvariant()
  if(-not(Test-Phase12BFileSha256 -Path $digestFile -ExpectedSha256 $digest)){throw 'exact checksum rejected'}
  if(Test-Phase12BFileSha256 -Path $digestFile -ExpectedSha256 ('0'*64)){throw 'wrong checksum accepted'}

  $state=[pscustomobject]@{IdentityConflict=$false;UnknownState=$false;DispatchFenced=$false;Quiescent=$false;TargetHostPrepared=$false;PackageVerified=$false;ExecutionAreaIdPreserved=$true;AclExact=$false;LegacyRegistered=$true;TargetRegistered=$false;ServiceInstalled=$false;ServiceRunning=$false;ServiceExact=$false;ActiveExact=$false;LegacyDirectoryRetained=$true}
  $actions=[Collections.Generic.List[string]]::new();$stages=[Collections.Generic.List[string]]::new()
  $readState={Copy-Object $state}
  $mutate={param($name)[void]$actions.Add($name);switch($name){'FenceDispatch'{$state.DispatchFenced=$true}'WaitForQuiescence'{$state.Quiescent=$true}'PrepareTargetHost'{$state.TargetHostPrepared=$true;$state.PackageVerified=$true;$state.AclExact=$true}'UnregisterLegacy'{$state.LegacyRegistered=$false}'RegisterTarget'{$state.TargetRegistered=$true}'InstallService'{$state.ServiceInstalled=$true;$state.ServiceExact=$true}'StartService'{$state.ServiceRunning=$true}'WriteActiveMetadata'{$state.ActiveExact=$true}'RestoreDispatch'{$state.DispatchFenced=$false}}}
  $persist={param($stage,$ignored)[void]$stages.Add($stage)}
  $result=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage LEGACY_VERIFIED -ReadState $readState -Mutate $mutate -Persist $persist
  Assert-Equal $result.Stage MIGRATION_COMPLETE 'full migration lifecycle'
  foreach($action in @('FenceDispatch','WaitForQuiescence','PrepareTargetHost','UnregisterLegacy','RegisterTarget','InstallService','StartService','WriteActiveMetadata','RestoreDispatch')){if($actions -notcontains $action){throw "migration action missing: $action"}}

  # Every durable stage must resume through the same production decision function.
  $allStages=@('LEGACY_VERIFIED','DISPATCH_FENCED','QUIESCENT','TARGET_HOST_PREPARED','LEGACY_RUNNER_UNREGISTERING','LEGACY_RUNNER_UNREGISTERED','TARGET_RUNNER_REGISTERING','TARGET_RUNNER_REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','SERVICE_RUNNING','ACTIVE_VERIFIED','MIGRATION_COMPLETE')
  foreach($start in $allStages){
    $state.DispatchFenced=$start -notin @('LEGACY_VERIFIED','MIGRATION_COMPLETE');$state.Quiescent=$true;$state.TargetHostPrepared=$start -notin @('LEGACY_VERIFIED','DISPATCH_FENCED','QUIESCENT');$state.PackageVerified=$state.TargetHostPrepared;$state.AclExact=$state.TargetHostPrepared
    $state.LegacyRegistered=$start -in @('LEGACY_VERIFIED','DISPATCH_FENCED','QUIESCENT','TARGET_HOST_PREPARED','LEGACY_RUNNER_UNREGISTERING')
    $state.TargetRegistered=$start -in @('TARGET_RUNNER_REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','SERVICE_RUNNING','ACTIVE_VERIFIED','MIGRATION_COMPLETE')
    $state.ServiceInstalled=$start -in @('SERVICE_INSTALLED','SERVICE_RUNNING','ACTIVE_VERIFIED','MIGRATION_COMPLETE');$state.ServiceRunning=$start -in @('SERVICE_RUNNING','ACTIVE_VERIFIED','MIGRATION_COMPLETE');$state.ServiceExact=$state.ServiceInstalled;$state.ActiveExact=$start -in @('ACTIVE_VERIFIED','MIGRATION_COMPLETE')
    if($start -eq 'MIGRATION_COMPLETE'){$state.DispatchFenced=$false}
    $resume=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage $start -ReadState $readState -Mutate $mutate -Persist $persist
    Assert-Equal $resume.Stage MIGRATION_COMPLETE "resume $start"
  }
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage TARGET_RUNNER_REGISTERING -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$true;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$false})) MANUAL_INTERVENTION_REQUIRED 'dual registration'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage SERVICE_INSTALLED -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$false;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$true;SafeApprovedRecoveryCandidate=$false})) RESUME_SAFE 'post-mutation crash window'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage SERVICE_INSTALLED -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$false;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$true})) RECOVER_WITH_APPROVAL 'bounded recovery candidate'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage '' -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$true;TargetRegistered=$false;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$false})) RETRY_SAFE 'pre-intent retry'

  # The entry point uses the same classifier and lifecycle; TestMode replaces only providers.
  $entry=Join-Path $root 'entry';New-Item -ItemType Directory -Path (Join-Path $entry 'callers'),(Join-Path $entry 'bin') -Force|Out-Null
  $execution=Join-Path $entry 'execution';$runnerRoot=Join-Path $entry 'runners';$entryRuntime=Join-Path $entry 'runtime';$profile=Join-Path $entry 'profile'
  New-Item -ItemType File -Path (Join-Path $entry 'environment.yaml'),(Join-Path $entry 'host.yaml'),(Join-Path $entry 'callers\caller.yaml')|Out-Null
  $yq=@'
@echo off
if "%1"=="--version" (echo yq version 4.53.6&exit /b 0)
set q=%2
if "%q%"==".schema_version" echo 1
if "%q%"==".host.config" echo host.yaml
if "%q%"==".host_id" echo test-host
if "%q%"==".platform" echo windows
if "%q%"==".paths.execution_root" echo __EXEC__
if "%q%"==".paths.runner_root" echo __RUNNER__
if "%q%"==".paths.runtime_root" echo __RUNTIME__
if "%q%"==".paths.profile_root" echo __PROFILE__
if "%q%"==".runner.mode" echo windows-service
if "%q%"==".runner.service_identity" echo network-service
if "%q%"==".runner.service_sid" echo S-1-5-20
if "%q%"==".runner.package_path" echo null
if "%q%"==".runner.labels[]" (echo self-hosted&echo Windows&echo X64&echo codex-automation)
if "%q%"==".execution.serialization" echo global-mutex
if "%q%"==".github.owner_id" echo 32902649
if "%q%"==".google_cloud.project_id" echo codex-automation-506111
if "%q%"==".google_cloud.workload_identity_provider_resource" echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions
if "%q%"==".automation.repository" echo kusa07/codex-automation
if "%q%"==".automation.workflow_path" echo .github/workflows/codex-run.yml
if "%q%"==".automation.active_workflow_sha" echo 374e48e8508e25e822dcd0673ca5cbb799e7d289
if "%q%"==".repository.full_name" echo kusa07/interest-gacha
if "%q%"==".repository.id" echo 1338414331
if "%q%"==".secret.id" echo codex-auth-interest-gacha
if "%q%"==".workflow.path" echo .github/workflows/codex-connectivity-test.yml
if "%q%"==".runner.enabled" echo true
if "%q%"==".runner.scope" echo repository
'@.Replace('__EXEC__',$execution).Replace('__RUNNER__',$runnerRoot).Replace('__RUNTIME__',$entryRuntime).Replace('__PROFILE__',$profile)
  Set-Content -LiteralPath (Join-Path $entry 'bin\yq.cmd') -Value $yq -NoNewline
  $migration=Copy-Object $base
  foreach($property in @{schema=1;execution_area_id='545b497b-f7f6-4d44-90e3-544afa1bab4f';legacy_runner_id='21';legacy_runner_name='codex-automation-windows-01';workflow_dispatch_state='active';IdentityConflict=$false;UnknownState=$false;DispatchFenced=$false;Quiescent=$true;TargetHostPrepared=$false;PackageVerified=$false;ExecutionAreaIdPreserved=$true;AclExact=$false;LegacyRegistered=$true;TargetRegistered=$false;ServiceInstalled=$false;ServiceRunning=$false;ServiceExact=$false;ActiveExact=$false;LegacyDirectoryRetained=$true}.GetEnumerator()){$migration|Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value -Force}
  $migrationFile=Join-Path $entry 'migration.json';$migration|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $migrationFile -NoNewline
  $oldPath=$env:PATH;$env:PATH="$(Join-Path $entry 'bin');$oldPath"
  try{& (Join-Path $PSScriptRoot 'migrate-host.ps1') -PrivateConfig (Join-Path $entry 'environment.yaml') -Approve -TestMode -FixtureRoot $entry -MigrationReadbackFile $migrationFile|Out-Null}finally{$env:PATH=$oldPath}
  $entryState=Get-Content -LiteralPath $migrationFile -Raw|ConvertFrom-Json
  Assert-Equal (Read-Phase12BMigrationIntent $entryRuntime).migration_stage MIGRATION_COMPLETE 'entry point durable completion'
  Assert-Equal $entryState.workflow_dispatch_state active 'entry point restored dispatch'
  foreach($action in @('FenceDispatch','PrepareTargetHost','UnregisterLegacy','RegisterTarget','InstallService','StartService','WriteActiveMetadata','RestoreDispatch')){if(@($entryState.mutation_calls) -notcontains $action){throw "entry point provider action missing: $action"}}

  'phase12b legacy host migration tests passed'
}finally{if(Test-Path Env:PHASE12B_TEST_ADAPTER){Remove-Item Env:PHASE12B_TEST_ADAPTER};if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
