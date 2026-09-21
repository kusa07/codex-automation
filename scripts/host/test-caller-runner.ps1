$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force

function Assert-Equal($Actual,$Expected,[string]$Message){if([string]$Actual -cne [string]$Expected){throw "$Message (expected=$Expected actual=$Actual)"}}
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-Throws([scriptblock]$Script,[string]$Message){$threw=$false;try{& $Script|Out-Null}catch{$threw=$true};if(-not $threw){throw $Message}}

$root=Join-Path ([IO.Path]::GetTempPath()) ('phase12b-caller-runner-'+[guid]::NewGuid().ToString('N'))
$oldPath=$null
New-Item -ItemType Directory -Path $root|Out-Null
try {
  $runnerRoot=Join-Path $root 'runner';$runtimeRoot=Join-Path $root 'runtime';$executionRoot=Join-Path $root 'execution';$profileRoot=Join-Path $root 'profile'
  $hostConfig=Join-Path $root 'host.yaml'
  @"
schema_version: 1
host_id: test-host
platform: windows
paths:
  execution_root: '$($executionRoot -replace '\\','/')'
  runner_root: '$($runnerRoot -replace '\\','/')'
  runtime_root: '$($runtimeRoot -replace '\\','/')'
  profile_root: '$($profileRoot -replace '\\','/')'
runner:
  mode: windows-service
  service_identity: network-service
  service_sid: S-1-5-20
  labels: [self-hosted, Windows, X64, codex-automation]
execution:
  serialization: global-mutex
  quiescence_timeout_seconds: 5
"@ | Set-Content -LiteralPath $hostConfig -NoNewline
  $bin=Join-Path $root 'bin';New-Item -ItemType Directory -Path $bin|Out-Null
  @'
@echo off
if "%1"=="--version" (echo yq version 4.44.1&exit /b 0)
set q=%2
if "%q%"==".schema_version" echo 1
if "%q%"==".host_id" echo test-host
if "%q%"==".platform" echo windows
if "%q%"==".paths.execution_root" echo __EXEC__
if "%q%"==".paths.runner_root" echo __RUNNER__
if "%q%"==".paths.runtime_root" echo __RUNTIME__
if "%q%"==".paths.profile_root" echo __PROFILE__
if "%q%"==".runner.mode" echo windows-service
if "%q%"==".runner.service_identity" echo network-service
if "%q%"==".runner.service_sid" echo S-1-5-20
if "%q%"==".runner.labels[]" (echo self-hosted&echo Windows&echo X64&echo codex-automation)
if "%q%"==".execution.quiescence_timeout_seconds" echo 5
'@.Replace('__EXEC__',$executionRoot).Replace('__RUNNER__',$runnerRoot).Replace('__RUNTIME__',$runtimeRoot).Replace('__PROFILE__',$profileRoot) | Set-Content -LiteralPath (Join-Path $bin 'yq.cmd') -NoNewline
  $oldPath=$env:PATH;$env:PATH="$bin;$oldPath"
  New-Item -ItemType Directory -Path $runtimeRoot,$profileRoot,$runnerRoot -Force|Out-Null
  & (Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1') -Action ensure -Root $executionRoot|Out-Null
  @{schema=1;host_id='test-host';service_identity='NT AUTHORITY\NETWORK SERVICE';service_sid='S-1-5-20';execution_root=$executionRoot;runtime_root=$runtimeRoot}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $runtimeRoot 'runtime.json') -NoNewline

  $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $runnerRoot -RepositoryId '12345'
  Assert-Equal $identity.RunnerDirectory ([IO.Path]::GetFullPath((Join-Path $runnerRoot 'repo-12345'))) 'canonical runner directory'
  Assert-Equal $identity.RunnerName 'codex-repo-12345' 'canonical runner name'
  Assert-Equal $identity.ServiceName '' 'service name must come from official .service read-back'

  $empty=[pscustomobject]@{Metadata=$null;LocalPresent=$false;GitHubPresent=$false;ServicePresent=$false;ExactMatch=$false;RunnerExact=$false;ServiceExact=$false;Service=$null;RepositoryNameDrift=$false;DuplicateRunner=$false;DuplicateService=$false;IdentityConflict=$false;RepositoryIdMismatch=$false;PathConflict=$false;LabelConflict=$false;ServiceIdentityConflict=$false}
  $c=Get-Phase12BCallerRunnerClassification -Observation $empty
  Assert-Equal $c.Snapshot NEW 'NEW snapshot';Assert-Equal $c.Lifecycle ABSENT 'ABSENT lifecycle';Assert-Equal $c.Recovery RETRY_SAFE 'NEW recovery'

  $registering=[pscustomobject]@{lifecycle_state='REGISTERING'}
  $preResource=$empty.PSObject.Copy();$preResource.Metadata=$registering
  $c=Get-Phase12BCallerRunnerClassification -Observation $preResource
  Assert-Equal $c.Snapshot PARTIAL 'REGISTERING pre-resource crash';Assert-Equal $c.Recovery RESUME_SAFE 'REGISTERING pre-resource recovery'
  $partial=$empty.PSObject.Copy();$partial.Metadata=$registering;$partial.LocalPresent=$true
  $c=Get-Phase12BCallerRunnerClassification -Observation $partial
  Assert-Equal $c.Snapshot PARTIAL 'REGISTERING partial';Assert-Equal $c.Recovery RESUME_SAFE 'REGISTERING resume'
  $postOfficialConfig=$empty.PSObject.Copy();$postOfficialConfig.Metadata=$registering;$postOfficialConfig.LocalPresent=$true;$postOfficialConfig.GitHubPresent=$true;$postOfficialConfig.ServicePresent=$true;$postOfficialConfig.RunnerExact=$true;$postOfficialConfig.ServiceExact=$true;$postOfficialConfig.Service=[pscustomobject]@{State='Stopped'}
  $c=Get-Phase12BCallerRunnerClassification -Observation $postOfficialConfig
  Assert-Equal $c.Snapshot PARTIAL 'REGISTERING post-official-config crash';Assert-Equal $c.Recovery RESUME_SAFE 'REGISTERING post-official-config recovery'
  $impossibleRegistered=$empty.PSObject.Copy();$impossibleRegistered.Metadata=[pscustomobject]@{lifecycle_state='REGISTERED'}
  $c=Get-Phase12BCallerRunnerClassification -Observation $impossibleRegistered
  Assert-Equal $c.Snapshot CONFLICT 'impossible REGISTERED topology';Assert-Equal $c.Recovery MANUAL_INTERVENTION_REQUIRED 'impossible REGISTERED recovery'
  foreach($invalidState in @('REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','ACTIVE','RETIRING','DISPATCH_DISABLED')){$negative=$empty.PSObject.Copy();$negative.Metadata=[pscustomobject]@{lifecycle_state=$invalidState};$negativeResult=Get-Phase12BCallerRunnerClassification -Observation $negative;Assert-Equal $negativeResult.Snapshot CONFLICT "$invalidState impossible topology"}
  $stoppedAfterRemoval=$empty.PSObject.Copy();$stoppedAfterRemoval.Metadata=[pscustomobject]@{lifecycle_state='SERVICE_STOPPED'};$stoppedResult=Get-Phase12BCallerRunnerClassification -Observation $stoppedAfterRemoval;Assert-Equal $stoppedResult.Snapshot PARTIAL 'SERVICE_STOPPED post-unregister crash';Assert-Equal $stoppedResult.Recovery RESUME_SAFE 'SERVICE_STOPPED post-unregister recovery'
  foreach($invalidState in @('RUNNER_REMOVED','RETIRED')){$negative=$empty.PSObject.Copy();$negative.Metadata=[pscustomobject]@{lifecycle_state=$invalidState};$negative.LocalPresent=$true;$negativeResult=Get-Phase12BCallerRunnerClassification -Observation $negative;Assert-Equal $negativeResult.Snapshot CONFLICT "$invalidState resource contradiction"}
  $rename=$empty.PSObject.Copy();$rename.Metadata=[pscustomobject]@{lifecycle_state='ACTIVE'};$rename.LocalPresent=$true;$rename.GitHubPresent=$true;$rename.ServicePresent=$true;$rename.ExactMatch=$true;$rename.RunnerExact=$true;$rename.ServiceExact=$true;$rename.Service=[pscustomobject]@{State='Running'};$rename.RepositoryNameDrift=$true
  $renameResult=Get-Phase12BCallerRunnerClassification -Observation $rename;Assert-Equal $renameResult.Snapshot PARTIAL 'same-ID repository rename snapshot';Assert-Equal $renameResult.Recovery RECOVER_WITH_APPROVAL 'same-ID repository rename recovery'

  $reconstruct=$empty.PSObject.Copy();$reconstruct.LocalPresent=$true;$reconstruct.GitHubPresent=$true;$reconstruct.ServicePresent=$true;$reconstruct.ExactMatch=$true
  $c=Get-Phase12BCallerRunnerClassification -Observation $reconstruct
  Assert-Equal $c.Snapshot PARTIAL 'metadata reconstruction partial';Assert-Equal $c.Recovery RECOVER_WITH_APPROVAL 'metadata reconstruction approval';Assert-True $c.ReconstructRuntimeMetadata 'metadata reconstruction plan flag'

  $conflict=$empty.PSObject.Copy();$conflict.DuplicateRunner=$true
  $c=Get-Phase12BCallerRunnerClassification -Observation $conflict
  Assert-Equal $c.Snapshot CONFLICT 'duplicate conflict';Assert-Equal $c.Recovery MANUAL_INTERVENTION_REQUIRED 'duplicate manual intervention'

  $metadata=Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot -LifecycleState ACTIVE
  $read=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot
  Assert-Equal $read.lifecycle_state ACTIVE 'metadata read/write';Assert-True ([string]$read.state_entered_at).EndsWith('Z') 'metadata UTC timestamp'
  $dateObject=$read.PSObject.Copy();$dateObject.state_entered_at=[DateTime]::Parse([string]$read.state_entered_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  Assert-True (Test-Phase12BMetadataIdentity -Metadata $dateObject -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot) 'DateTime metadata timestamp was not locale-independent'
  $offsetObject=$read.PSObject.Copy();$offsetObject.state_entered_at=[DateTimeOffset]::Parse([string]$read.state_entered_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  Assert-True (Test-Phase12BMetadataIdentity -Metadata $offsetObject -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot) 'DateTimeOffset metadata timestamp was rejected'
  $localizedObject=$read.PSObject.Copy();$localizedObject.state_entered_at=([DateTime]::Now.ToString())
  Assert-Throws {Test-Phase12BMetadataIdentity -Metadata $localizedObject -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot} 'localized metadata timestamp was accepted'
  Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent (Get-Phase12BRunnerMetadataPath $runtimeRoot 12345)) -Filter '*.tmp').Count 0 'atomic metadata temp cleanup'
  $first=[string]$metadata.state_entered_at;Start-Sleep -Milliseconds 10
  $updated=Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot -LifecycleState RETIRING
  Assert-True ([string]$updated.state_entered_at -cne $first) 'state_entered_at must update'
  $reread=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot
  Assert-Equal $reread.lifecycle_state RETIRING 'metadata second write/read round-trip'
  $staleTemp=Join-Path (Split-Path -Parent (Get-Phase12BRunnerMetadataPath $runtimeRoot 12345)) '.12345.stale.tmp';Set-Content -LiteralPath $staleTemp -Value residue -NoNewline
  Assert-Throws {Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot} 'metadata temp residue was ignored on read'
  Assert-Throws {Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot -LifecycleState ACTIVE} 'metadata temp residue was ignored'
  Remove-Item -LiteralPath $staleTemp -Force
  $path=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345
  Set-Content -LiteralPath $path -Value '{bad json' -NoNewline
  Assert-Throws {Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot} 'malformed metadata accepted'
  Set-Content -LiteralPath $path -Value '{"schema":99}' -NoNewline
  Assert-Throws {Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/repo' -RunnerRoot $runnerRoot} 'unsupported metadata accepted'
  Remove-Item -LiteralPath $path -Force

  $renameMetadata=Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/old-name' -RunnerRoot $runnerRoot -LifecycleState RUNNER_REMOVED -ServiceName ''
  $renameRead=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName 'owner/new-name' -RunnerRoot $runnerRoot
  Assert-Equal $renameRead.repository_id 12345 'repository rename changed immutable identity'
  Remove-Item -LiteralPath (Get-Phase12BRunnerMetadataPath $runtimeRoot 12345) -Force

  $fixture=[ordered]@{schema=1;repository_id='12345';local_present=$false;runners=@();services=@();workflow_state='ABSENT';current_run_repository_id=''}
  Write-Phase12BCallerRunnerFixture -FixtureRoot $root -Fixture $fixture
  $fixtureBefore=(Get-Content -LiteralPath (Join-Path $root 'caller-runner-fixture.json') -Raw)
  $output=& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Inspect -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root
  Assert-True (($output -join "`n") -match 'CALLER_RUNNER_SNAPSHOT_STATE=NEW') 'Inspect did not classify NEW'
  Assert-True (($output -join "`n") -match 'MUTATIONS_PERFORMED=NONE') 'Inspect reported mutation'
  Assert-True (($output -join "`n") -match '(?m)^STATE_ENTERED_AT=') 'Inspect omitted STATE_ENTERED_AT audit field'
  Assert-True (($output -join "`n") -match '(?m)^POSTCONDITION=READ_ONLY_SNAPSHOT$') 'Inspect omitted POSTCONDITION audit field'
  Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'caller-runner-fixture.json') -Raw) $fixtureBefore 'Inspect mutated fixture'
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Inspect -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode} 'TestMode without fixture accepted'
  $env:PHASE12B_TEST_MODE='1';Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Inspect -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345} 'environment test activation accepted';Remove-Item Env:PHASE12B_TEST_MODE
  $env:PHASE12B_RUNNER_APPLY='arbitrary-command';Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Inspect -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345} 'production arbitrary adapter accepted';Remove-Item Env:PHASE12B_RUNNER_APPLY

  & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root|Out-Null
  $active=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot
  Assert-Equal $active.lifecycle_state ACTIVE 'Onboard did not reach ACTIVE'
  $verify=& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Verify -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root
  Assert-True (($verify -join "`n") -match 'CALLER_RUNNER_SNAPSHOT_STATE=CONSISTENT') 'ACTIVE verification failed'
  $beginOffboard=& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Offboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -BeginRetirement -TestMode -FixtureRoot $root
  Assert-True (($beginOffboard -join "`n") -match 'CALLER_RUNNER_LIFECYCLE_STATE_AFTER=RETIRING') 'Offboard did not fix RETIRING before workflow mutation'
  Assert-Equal @((Read-Phase12BCallerRunnerFixture -FixtureRoot $root).services).Count 1 'BeginRetirement mutated service before workflow read-back'
  $firstOffboard=& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Offboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root
  Assert-True (($firstOffboard -join "`n") -match 'CALLER_RUNNER_LIFECYCLE_STATE_AFTER=RUNNER_REMOVED') 'Offboard retired local metadata before cloud finalization'
  & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Offboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -FinalizeRetirement -TestMode -FixtureRoot $root|Out-Null
  $retired=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -State retired
  Assert-Equal $retired.lifecycle_state RETIRED 'Offboard did not reach RETIRED'
  Assert-True (-not(Test-Path -LiteralPath (Get-Phase12BRunnerMetadataPath $runtimeRoot 12345))) 'active metadata remains after retirement'
  Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -LifecycleState RUNNER_REMOVED -ServiceName ''|Out-Null
  & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Offboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -FinalizeRetirement -TestMode -FixtureRoot $root|Out-Null
  Assert-True (-not(Test-Path -LiteralPath (Get-Phase12BRunnerMetadataPath $runtimeRoot 12345))) 'retirement-overlap crash resume did not remove active metadata'
  & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/renamed-repo -RepositoryId 12345 -TestMode -FixtureRoot $root|Out-Null
  $renamedActive=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/renamed-repo -RunnerRoot $runnerRoot
  Assert-Equal $renamedActive.lifecycle_state ACTIVE 'same-ID renamed repository did not re-onboard';Assert-Equal $renamedActive.repository_full_name owner/renamed-repo 'renamed repository display metadata was not reconciled'

  foreach($resume in @('REGISTERING','REGISTERED','SERVICE_INSTALLING')){
    $activePath=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345;$retiredPath=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345 -State retired
    foreach($metadataPath in @($activePath,$retiredPath)){if(Test-Path -LiteralPath $metadataPath){Remove-Item -LiteralPath $metadataPath -Force}}
    $hasRunner=$resume -ne 'REGISTERING';$hasService=$resume -eq 'SERVICE_INSTALLED';$serviceName='actions.runner.owner-repo.codex-repo-12345';New-Item -ItemType Directory -Path (Join-Path $identity.RunnerDirectory 'bin') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory 'config.cmd') -Value '@echo off' -NoNewline;if($hasService){Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory '.service') -Value $serviceName -NoNewline;Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe') -Value fixture -NoNewline}else{Remove-Item -LiteralPath (Join-Path $identity.RunnerDirectory '.service') -Force -ErrorAction SilentlyContinue}
    $resumeFixture=[ordered]@{schema=1;repository_id='12345';repository_full_name='owner/repo';local_present=$true;runners=if($hasRunner){@([ordered]@{name='codex-repo-12345';labels=@('self-hosted','Windows','X64','codex-automation')})}else{@()};services=if($hasService){@([ordered]@{Name=$serviceName;PathName=('"{0}"' -f (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe'));StartName='NT AUTHORITY\NETWORK SERVICE';State='Running'})}else{@()};workflow_state='ABSENT';current_run_repository_id=''}
    Write-Phase12BCallerRunnerFixture -FixtureRoot $root -Fixture $resumeFixture
    Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -LifecycleState $resume|Out-Null
    & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root|Out-Null
    $resumed=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot
    Assert-Equal $resumed.lifecycle_state ACTIVE "Onboard resume from $resume"
  }

  function Set-ServiceInstalledFixture {
    param(
      [ValidateSet('Running','Stopped')][string]$State='Stopped',
      [ValidateSet('SUCCESS','ERROR','NO_STATE_CHANGE')][string]$StartBehavior='SUCCESS',
      [string]$ServiceIdentity='NT AUTHORITY\NETWORK SERVICE',
      [string]$ServicePath='',
      [switch]$MissingService
    )
    $activePath=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345;$retiredPath=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345 -State retired
    foreach($metadataPath in @($activePath,$retiredPath)){if(Test-Path -LiteralPath $metadataPath){Remove-Item -LiteralPath $metadataPath -Force}}
    if(Test-Path -LiteralPath $identity.RunnerDirectory){Remove-Item -LiteralPath $identity.RunnerDirectory -Recurse -Force}
    $serviceName='actions.runner.owner-repo.codex-repo-12345';New-Item -ItemType Directory -Path (Join-Path $identity.RunnerDirectory 'bin') -Force|Out-Null
    Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory 'config.cmd') -Value '@echo off' -NoNewline
    Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory '.service') -Value $serviceName -NoNewline
    Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe') -Value fixture -NoNewline
    if(-not $ServicePath){$ServicePath='"{0}"' -f (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe')}
    $services=if($MissingService){@()}else{@([ordered]@{Name=$serviceName;PathName=$ServicePath;StartName=$ServiceIdentity;State=$State})}
    Write-Phase12BCallerRunnerFixture -FixtureRoot $root -Fixture ([ordered]@{schema=1;repository_id='12345';repository_full_name='owner/repo';local_present=$true;runners=@([ordered]@{name='codex-repo-12345';labels=@('self-hosted','Windows','X64','codex-automation')});services=$services;workflow_state='ABSENT';current_run_repository_id='';start_service_behavior=$StartBehavior;start_service_call_count=0})
    Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -LifecycleState SERVICE_INSTALLED -ServiceName $serviceName|Out-Null
  }

  # The canonical SERVICE_INSTALLED -> ACTIVE transition is shared by the
  # production and fixture providers.  Stopped must be started and read back.
  Set-ServiceInstalledFixture -State Stopped
  & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root|Out-Null
  $stoppedResumeFixture=Read-Phase12BCallerRunnerFixture -FixtureRoot $root
  Assert-Equal $stoppedResumeFixture.start_service_call_count 1 'Stopped SERVICE_INSTALLED did not call StartService exactly once'
  Assert-Equal $stoppedResumeFixture.services[0].State Running 'Stopped SERVICE_INSTALLED was not read back Running'
  Assert-Equal (Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot).lifecycle_state ACTIVE 'Stopped SERVICE_INSTALLED did not reach ACTIVE'

  Set-ServiceInstalledFixture -State Running
  & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root|Out-Null
  $runningResumeFixture=Read-Phase12BCallerRunnerFixture -FixtureRoot $root
  Assert-Equal $runningResumeFixture.start_service_call_count 0 'Running SERVICE_INSTALLED replayed StartService'
  Assert-Equal (Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot).lifecycle_state ACTIVE 'Running SERVICE_INSTALLED crash window did not reach ACTIVE'

  Set-ServiceInstalledFixture -State Stopped -StartBehavior ERROR
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root} 'StartService provider error reached ACTIVE'
  Assert-Equal (Read-Phase12BCallerRunnerFixture -FixtureRoot $root).start_service_call_count 1 'StartService error was not recorded'
  Assert-Equal (Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot).lifecycle_state SERVICE_INSTALLED 'StartService error advanced lifecycle metadata'

  Set-ServiceInstalledFixture -State Stopped -StartBehavior NO_STATE_CHANGE
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root} 'Stopped post-start read-back reached ACTIVE'
  Assert-Equal (Read-Phase12BCallerRunnerFixture -FixtureRoot $root).services[0].State Stopped 'NO_STATE_CHANGE fixture unexpectedly changed Service state'
  Assert-Equal (Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot).lifecycle_state SERVICE_INSTALLED 'Stopped post-start read-back advanced lifecycle metadata'

  Set-ServiceInstalledFixture -MissingService
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root} 'Missing SERVICE_INSTALLED Service reached ACTIVE'
  Set-ServiceInstalledFixture -ServiceIdentity 'NT AUTHORITY\SYSTEM'
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root} 'Wrong SERVICE_INSTALLED Service identity reached ACTIVE'
  Set-ServiceInstalledFixture -ServicePath 'C:\unexpected\RunnerService.exe'
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Onboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root} 'Wrong SERVICE_INSTALLED Service path reached ACTIVE'

  foreach($resume in @('RETIRING','DISPATCH_DISABLED','SERVICE_STOPPED','RUNNER_REMOVED')){
    $activePath=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345;$retiredPath=Get-Phase12BRunnerMetadataPath $runtimeRoot 12345 -State retired
    foreach($metadataPath in @($activePath,$retiredPath)){if(Test-Path -LiteralPath $metadataPath){Remove-Item -LiteralPath $metadataPath -Force}}
    $runnerPresent=$resume -notin @('RUNNER_REMOVED');$servicePresent=$resume -notin @('RUNNER_REMOVED');$serviceName='actions.runner.owner-repo.codex-repo-12345';if($runnerPresent){New-Item -ItemType Directory -Path (Join-Path $identity.RunnerDirectory 'bin') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory '.service') -Value $serviceName -NoNewline;Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe') -Value fixture -NoNewline}
    $resumeFixture=[ordered]@{schema=1;repository_id='12345';repository_full_name='owner/repo';local_present=$runnerPresent;runners=if($runnerPresent){@([ordered]@{name='codex-repo-12345';labels=@('self-hosted','Windows','X64','codex-automation')})}else{@()};services=if($servicePresent){@([ordered]@{Name=$serviceName;PathName=('"{0}"' -f (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe'));StartName='NT AUTHORITY\NETWORK SERVICE';State=$(if($resume -eq 'SERVICE_STOPPED'){'Stopped'}else{'Running'})})}else{@()};workflow_state='ABSENT';current_run_repository_id=''}
    Write-Phase12BCallerRunnerFixture -FixtureRoot $root -Fixture $resumeFixture
    Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -LifecycleState $resume|Out-Null
    & (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Offboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -FinalizeRetirement -TestMode -FixtureRoot $root|Out-Null
    $resumed=Read-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -State retired
    Assert-Equal $resumed.lifecycle_state RETIRED "Offboard resume from $resume"
  }

  $serviceName='actions.runner.owner-repo.codex-repo-12345';New-Item -ItemType Directory -Path (Join-Path $identity.RunnerDirectory 'bin') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory '.service') -Value $serviceName -NoNewline;Set-Content -LiteralPath (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe') -Value fixture -NoNewline
  Write-Phase12BCallerRunnerFixture -FixtureRoot $root -Fixture ([ordered]@{schema=1;repository_id='12345';repository_full_name='owner/repo';local_present=$true;runners=@([ordered]@{name='codex-repo-12345';labels=@('self-hosted','Windows','X64','codex-automation')});services=@([ordered]@{Name=$serviceName;PathName=('"{0}"' -f (Join-Path $identity.RunnerDirectory 'bin\RunnerService.exe'));StartName='NT AUTHORITY\NETWORK SERVICE';State='Running'});workflow_state='ABSENT';current_run_repository_id='12345';mutex_state='BUSY'})
  Write-Phase12BRunnerMetadata -RuntimeRoot $runtimeRoot -RepositoryId 12345 -RepositoryFullName owner/repo -RunnerRoot $runnerRoot -LifecycleState ACTIVE -ServiceName $serviceName|Out-Null
  Assert-Throws {& (Join-Path $PSScriptRoot 'caller-runner.ps1') -Action Offboard -HostConfig $hostConfig -RepositoryFullName owner/repo -RepositoryId 12345 -TestMode -FixtureRoot $root} 'target execution did not stop offboard'
  $blockedFixture=Read-Phase12BCallerRunnerFixture -FixtureRoot $root;Assert-Equal @($blockedFixture.runners).Count 1 'quiescence timeout unregistered runner';Assert-Equal @($blockedFixture.services).Count 1 'quiescence timeout stopped service'

  $quiescenceRoot=Join-Path $root 'quiescence';New-Item -ItemType Directory -Path (Join-Path $quiescenceRoot 'state') -Force|Out-Null
  $q=Wait-Phase12BCallerQuiescence -ExecutionRoot $quiescenceRoot -RepositoryId 12345 -RepositoryFullName owner/repo -TimeoutSeconds 1 -TestMode
  Assert-Equal $q.Reason NO_CURRENT_EXECUTION 'no execution quiescence'
  @{schema=1;execution_id='other-run';repository_id='999';github_run_id='77';github_run_attempt='1';started_at_utc='2026-09-17T00:00:00Z'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $quiescenceRoot 'state\current-run.json') -NoNewline
  $q=Wait-Phase12BCallerQuiescence -ExecutionRoot $quiescenceRoot -RepositoryId 12345 -RepositoryFullName owner/repo -TimeoutSeconds 1 -TestMode -TestMutexState BUSY
  Assert-Equal $q.Reason OTHER_CALLER_EXECUTION 'other caller should not block'
  @{schema=1;execution_id='target-run';repository_id='12345';github_run_id='77';github_run_attempt='1';started_at_utc='2026-09-17T00:00:00Z'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $quiescenceRoot 'state\current-run.json') -NoNewline
  $q=Wait-Phase12BCallerQuiescence -ExecutionRoot $quiescenceRoot -RepositoryId 12345 -RepositoryFullName owner/repo -TimeoutSeconds 1 -TestMode -TestMutexState BUSY
  Assert-Equal $q.Reason QUIESCENCE_TIMEOUT 'target caller timeout';Assert-Equal $q.Recovery RETRY_SAFE 'target caller recovery'
  Set-Content -LiteralPath (Join-Path $quiescenceRoot 'state\current-run.json') -Value '{bad' -NoNewline
  $q=Wait-Phase12BCallerQuiescence -ExecutionRoot $quiescenceRoot -RepositoryId 12345 -RepositoryFullName owner/repo -TimeoutSeconds 1 -TestMode -TestMutexState BUSY
  Assert-Equal $q.Reason QUIESCENCE_TIMEOUT 'unknown ownership timeout'
  @{repository_id='999'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $quiescenceRoot 'state\current-run.json') -NoNewline
  $q=Wait-Phase12BCallerQuiescence -ExecutionRoot $quiescenceRoot -RepositoryId 12345 -RepositoryFullName owner/repo -TimeoutSeconds 1 -TestMode -TestMutexState BUSY
  Assert-Equal $q.Reason QUIESCENCE_TIMEOUT 'repository-id-only partial JSON was accepted as ownership evidence'
  @{schema=1;execution_id='wrong-type';repository_id=999;github_run_id='77';github_run_attempt='1';started_at_utc='2026-09-17T00:00:00Z'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $quiescenceRoot 'state\current-run.json') -NoNewline
  $q=Wait-Phase12BCallerQuiescence -ExecutionRoot $quiescenceRoot -RepositoryId 12345 -RepositoryFullName owner/repo -TimeoutSeconds 1 -TestMode -TestMutexState BUSY
  Assert-Equal $q.Reason QUIESCENCE_TIMEOUT 'wrong current-run types were accepted'
  Remove-Item -LiteralPath (Join-Path $quiescenceRoot 'state\current-run.json') -Force

  $activeState=@{schema=1;execution_id='other-active';repository_id='999';github_run_id='88';github_run_attempt='1';started_at_utc='2026-09-17T00:00:00Z'}|ConvertTo-Json -Compress
  Set-Content -LiteralPath (Join-Path $executionRoot 'state\current-run.json') -Value $activeState -NoNewline
  Assert-Equal (Get-Phase12BHostState -RuntimeRoot $runtimeRoot -ExecutionRoot $executionRoot -HostId test-host -ProfileRoot $profileRoot -RunnerRoot $runnerRoot) EXISTING 'other caller active corrupted HOST_STATE'
  Remove-Item -LiteralPath (Join-Path $executionRoot 'state\current-run.json') -Force

  $marker=Get-Content -LiteralPath (Join-Path $executionRoot '.codex-automation-managed') -Raw|ConvertFrom-Json
  $mutexName="Global\CodexAutomation-ExecutionArea-$([string]$marker.execution_area_id -replace '-','')"
  if(-not('Phase12BAbandonedMutexFixture' -as [type])){Add-Type -TypeDefinition @'
using System.Threading;
public static class Phase12BAbandonedMutexFixture {
    private static Mutex held;
    public static void Create(string name) {
        var thread = new Thread(() => { held = new Mutex(false, name); held.WaitOne(); });
        thread.Start(); thread.Join();
    }
}
'@}
  [Phase12BAbandonedMutexFixture]::Create($mutexName)
  Assert-Equal (Get-Phase12BExecutionMutexState -ExecutionRoot $executionRoot) ABANDONED 'abandoned mutex was not classified'
  Assert-Equal (Get-Phase12BExecutionMutexState -ExecutionRoot $executionRoot) FREE 'abandoned mutex ownership leaked after read-back'
  foreach($case in @(
    @{Mutex='FREE';Current='ABSENT';Id='';Jobs=0;Residual=0;Unknown=$false;Shared=$false;Consistent=$false;Expected='PASS'},
    @{Mutex='BUSY';Current='VALID';Id='12345';Jobs=0;Residual=0;Unknown=$false;Shared=$true;Consistent=$true;Expected='WAIT'},
    @{Mutex='BUSY';Current='VALID';Id='999';Jobs=0;Residual=0;Unknown=$false;Shared=$true;Consistent=$true;Expected='PASS'},
    @{Mutex='BUSY';Current='VALID';Id='999';Jobs=0;Residual=0;Unknown=$false;Shared=$true;Consistent=$false;Expected='WAIT'},
    @{Mutex='BUSY';Current='VALID';Id='999';Jobs=0;Residual=1;Unknown=$false;Shared=$true;Consistent=$true;Expected='WAIT'},
    @{Mutex='BUSY';Current='VALID';Id='999';Jobs=1;Residual=0;Unknown=$false;Shared=$true;Consistent=$true;Expected='WAIT'},
    @{Mutex='BUSY';Current='ABSENT';Id='';Jobs=0;Residual=0;Unknown=$false;Shared=$false;Consistent=$false;Expected='WAIT'},
    @{Mutex='UNKNOWN';Current='ABSENT';Id='';Jobs=0;Residual=0;Unknown=$false;Shared=$false;Consistent=$false;Expected='WAIT'},
    @{Mutex='ABANDONED';Current='ABSENT';Id='';Jobs=0;Residual=0;Unknown=$false;Shared=$false;Consistent=$false;Expected='WAIT'},
    @{Mutex='FREE';Current='ABSENT';Id='';Jobs=0;Residual=0;Unknown=$false;Shared=$true;Consistent=$false;Expected='WAIT'},
    @{Mutex='BUSY';Current='MALFORMED';Id='';Jobs=0;Residual=0;Unknown=$false;Shared=$true;Consistent=$false;Expected='WAIT'},
    @{Mutex='FREE';Current='ABSENT';Id='';Jobs=1;Residual=0;Unknown=$false;Shared=$false;Consistent=$false;Expected='WAIT'},
    @{Mutex='FREE';Current='ABSENT';Id='';Jobs=0;Residual=1;Unknown=$false;Shared=$false;Consistent=$false;Expected='WAIT'},
    @{Mutex='FREE';Current='ABSENT';Id='';Jobs=0;Residual=0;Unknown=$true;Shared=$false;Consistent=$false;Expected='WAIT'})){
    $decision=Get-Phase12BQuiescenceDecision -MutexState $case.Mutex -CurrentRunState $case.Current -CurrentRepositoryId $case.Id -TargetRepositoryId 12345 -ActiveGitHubJobCount $case.Jobs -TargetResidualCount $case.Residual -ResidualOwnershipUnknown:$case.Unknown -SharedResidualPresent:$case.Shared -SharedResidualConsistentWithOtherCaller:$case.Consistent
    Assert-Equal $decision.Decision $case.Expected "quiescence decision $($case.Mutex)/$($case.Current)/$($case.Id)"
  }
  $realisticRoot=Join-Path $root 'other-caller-shared-residual';$otherWorkspace=Join-Path $realisticRoot 'workspaces\other-job';$otherCodexHome=Join-Path $realisticRoot 'codex-home\other-job'
  New-Item -ItemType Directory -Path $otherWorkspace,$otherCodexHome -Force|Out-Null
  @{repository='owner/other'}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $otherWorkspace '.codex-workspace-owned.json') -NoNewline
  Set-Content -LiteralPath (Join-Path $otherCodexHome 'auth.json') -Value '{}' -NoNewline
  $realisticResidual=Get-Phase12BResidualState -ExecutionRoot $realisticRoot -RepositoryFullName owner/repo
  Assert-Equal $realisticResidual.TargetCount 0 'other caller fixture became target residual'
  Assert-True (-not $realisticResidual.OwnershipUnknown) 'valid other caller workspace became ambiguous residual'
  Assert-True $realisticResidual.SharedResidualPresent 'shared codex-home residual was not observed'
  Assert-True $realisticResidual.SharedResidualConsistentWithOtherCaller 'matching other caller codex-home was not associated with its workspace'
  $realisticDecision=Get-Phase12BQuiescenceDecision -MutexState BUSY -CurrentRunState VALID -CurrentRepositoryId 999 -TargetRepositoryId 123 -TargetResidualCount $realisticResidual.TargetCount -ResidualOwnershipUnknown:$realisticResidual.OwnershipUnknown -SharedResidualPresent:$realisticResidual.SharedResidualPresent -SharedResidualConsistentWithOtherCaller:$realisticResidual.SharedResidualConsistentWithOtherCaller
  Assert-Equal $realisticDecision.Decision PASS 'other caller active with shared residual blocked target offboard'
  Assert-Equal $realisticDecision.Reason OTHER_CALLER_EXECUTION 'other caller shared residual reason'
  'PHASE12B_CALLER_RUNNER_TEST=PASS'
} finally {
  if($oldPath){$env:PATH=$oldPath}
  if(Test-Path Env:PHASE12B_TEST_MODE){Remove-Item Env:PHASE12B_TEST_MODE}
  if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
