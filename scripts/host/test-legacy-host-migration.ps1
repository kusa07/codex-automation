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
    github_actual_repository_id='1338414331';github_actual_repository_full_name='kusa07/interest-gacha';github_repository_read_error=$false
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

  $packageVersion='2.337.0';$packageSha='1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc'
  $identity=[pscustomobject]@{OperationId=[guid]::NewGuid().ToString('D');RepositoryId='1338414331';RepositoryFullName='kusa07/interest-gacha';LegacyRunnerDirectory='C:\codex-runner';LegacyRunnerId='21';LegacyRunnerName='codex-automation-windows-01';ExecutionAreaId='545b497b-f7f6-4d44-90e3-544afa1bab4f';TargetRunnerDirectory='C:\codex-runners\repo-1338414331';TargetRunnerName='codex-repo-1338414331';PackageVersion=$packageVersion;PackageSha256=$packageSha}
  $runtime=Join-Path $root 'runtime'
  $written=Initialize-Phase12BMigrationIntent -RuntimeRoot $runtime -Identity $identity
  if(-not(Test-Phase12BMigrationIntent $written)){throw 'valid migration intent rejected'}
  $read=Read-Phase12BMigrationIntent -RuntimeRoot $runtime;Assert-Equal $read.migration_stage LEGACY_VERIFIED 'intent round-trip'
  Assert-Throws {Initialize-Phase12BMigrationIntent -RuntimeRoot $runtime -Identity $identity} 'duplicate initial intent'
  Write-Phase12BMigrationIntent -RuntimeRoot $runtime -Stage DISPATCH_FENCED -Identity $identity|Out-Null
  Assert-Equal (Read-Phase12BMigrationIntent $runtime).migration_stage DISPATCH_FENCED 'atomic intent update'

  $package=Get-Phase12BRunnerPackageContract -Version $packageVersion -Sha256 $packageSha
  Assert-Equal $package.Version 2.337.0 'package version'
  Assert-Equal $package.ArchiveName actions-runner-win-x64-2.337.0.zip 'package archive'
  Assert-Equal $package.Uri 'https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-win-x64-2.337.0.zip' 'package source'
  Assert-Equal $package.Sha256 $packageSha 'package digest'
  $release=[pscustomobject]@{tag_name='v2.337.0';assets=@([pscustomobject]@{name=$package.ArchiveName;browser_download_url=$package.Uri;digest="sha256:$packageSha";state='uploaded'})}
  if(-not(Test-Phase12BRunnerReleaseAsset -Contract $package -Release $release)){throw 'official release asset rejected'}
  $badUrl=Copy-Object $release;$badUrl.assets[0].browser_download_url='https://example.invalid/runner.zip';if(Test-Phase12BRunnerReleaseAsset -Contract $package -Release $badUrl){throw 'arbitrary package URL accepted'}
  $badDigest=Copy-Object $release;$badDigest.assets[0].digest=('sha256:'+('0'*64));if(Test-Phase12BRunnerReleaseAsset -Contract $package -Release $badDigest){throw 'wrong official asset digest accepted'}
  foreach($invalidVersion in @('latest','2.337','v2.337.0','2.337.0/../x')){Assert-Throws {Get-Phase12BRunnerPackageContract -Version $invalidVersion -Sha256 $packageSha} "invalid package version $invalidVersion"}
  $digestFile=Join-Path $root 'digest.bin';[IO.File]::WriteAllText($digestFile,'phase12b',[Text.UTF8Encoding]::new($false));$digest=(Get-FileHash $digestFile -Algorithm SHA256).Hash.ToLowerInvariant()
  if(-not(Test-Phase12BFileSha256 -Path $digestFile -ExpectedSha256 $digest)){throw 'exact checksum rejected'}
  if(Test-Phase12BFileSha256 -Path $digestFile -ExpectedSha256 ('0'*64)){throw 'wrong checksum accepted'}

  # Every runner page is authoritative; truncation and duplicate identities fail closed.
  function New-TestRunner([int]$id){[pscustomobject]@{id=$id;name="runner-$id";status='offline';busy=$false;labels=@()}}
  function New-RunnerPage([int]$total,[int]$first,[int]$count){[pscustomobject]@{total_count=$total;runners=@(for($i=0;$i -lt $count;$i++){New-TestRunner ($first+$i)})}}
  Assert-Equal (Get-Phase12BCompleteRunnerList -FetchPages {@(New-RunnerPage 1 1 1)}).TotalCount 1 'single runner page'
  Assert-Equal (Get-Phase12BCompleteRunnerList -FetchPages {@(New-RunnerPage 100 1 100)}).TotalCount 100 'exact full runner page'
  $page101=Get-Phase12BCompleteRunnerList -FetchPages {@((New-RunnerPage 101 1 100),(New-RunnerPage 101 101 1))}
  Assert-Equal @($page101.Runners|Where-Object{$_.id -eq 101}).Count 1 'runner on page two'
  $pageTwoRunner=@($page101.Runners|Where-Object{$_.id -eq 101})[0];$pageTwoRunner.labels=@(@('self-hosted','Windows','X64','codex-automation')|ForEach-Object{[pscustomobject]@{name=$_}})
  $pageTwoLocal=[pscustomobject]@{agentId=101;agentName='runner-101';gitHubUrl='https://github.com/example/paged'}
  $pageTwoMatch=Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $pageTwoLocal -CallerRepository 'example/paged' -CallerRepositoryId '999999999' -ActualRepositoryId '999999999' -GitHubRunners $page101.Runners -ExpectedLabels @('self-hosted','Windows','X64','codex-automation')
  Assert-Equal $pageTwoMatch.GitHubRunnerCount 1 'legacy runner retained on page two';if(-not $pageTwoMatch.GitHubRunnerExact){throw 'page two legacy registration was not exact'}
  $page201=Get-Phase12BCompleteRunnerList -FetchPages {@((New-RunnerPage 201 1 100),(New-RunnerPage 201 101 100),(New-RunnerPage 201 201 1))}
  Assert-Equal @($page201.Runners|Where-Object{$_.id -eq 201}).Count 1 'runner on page three'
  Assert-Throws {Get-Phase12BCompleteRunnerList -FetchPages {throw 'page read failed'}} 'runner page read failure'
  Assert-Throws {Get-Phase12BCompleteRunnerList -FetchPages {@(New-RunnerPage 101 1 100)}} 'truncated runner pagination'
  Assert-Throws {Get-Phase12BCompleteRunnerList -FetchPages {@(New-RunnerPage 10001 1 100)}} 'runner pagination safety limit'
  $duplicateSecond=New-RunnerPage 101 1 1
  Assert-Throws {Get-Phase12BCompleteRunnerList -FetchPages {@((New-RunnerPage 101 1 100),$duplicateSecond)}} 'duplicate runner ID across pages'

  # Package extraction is isolated beneath operation-owned staging and atomically published.
  function New-PackageTree([string]$path,[switch]$Incomplete){New-Item -ItemType Directory -Path (Join-Path $path 'bin') -Force|Out-Null;foreach($file in @('config.cmd','run.cmd','bin\Runner.Listener.exe')){New-Item -ItemType File -Path (Join-Path $path $file) -Force|Out-Null};if(-not $Incomplete){New-Item -ItemType File -Path (Join-Path $path 'bin\RunnerService.exe') -Force|Out-Null}}
  $packageSource=Join-Path $root 'package-source';New-PackageTree $packageSource
  $packageArchive=Join-Path $root 'runner.zip';Compress-Archive -Path (Join-Path $packageSource '*') -DestinationPath $packageArchive
  $atomicRoot=Join-Path $root 'atomic-runners';New-Item -ItemType Directory -Path $atomicRoot|Out-Null
  $partialOperation=[guid]::NewGuid().ToString('D');$partialTarget=Join-Path $atomicRoot 'repo-1';$partialStage=Join-Path $atomicRoot ".migration-staging\$partialOperation\runner";New-Item -ItemType Directory -Path $partialStage -Force|Out-Null;New-Item -ItemType File -Path (Join-Path $partialStage 'partial.tmp')|Out-Null
  Assert-Equal (Install-Phase12BRunnerPackageAtomically -RunnerRoot $atomicRoot -TargetRunnerDirectory $partialTarget -OperationId $partialOperation -PackagePath $packageArchive).State PUBLISHED 'partial staging rebuild and publish'
  if(-not(Test-Phase12BRunnerPackageTree $partialTarget)){throw 'published package tree is not exact'}
  Assert-Equal (Install-Phase12BRunnerPackageAtomically -RunnerRoot $atomicRoot -TargetRunnerDirectory $partialTarget -OperationId $partialOperation -PackagePath $packageArchive).State ALREADY_PUBLISHED 'post-publish crash resume'
  $completeOperation=[guid]::NewGuid().ToString('D');$completeRoot=Join-Path $root 'complete-runners';New-Item -ItemType Directory -Path $completeRoot|Out-Null;$completeStage=Join-Path $completeRoot ".migration-staging\$completeOperation\runner";New-PackageTree $completeStage
  Assert-Equal (Install-Phase12BRunnerPackageAtomically -RunnerRoot $completeRoot -TargetRunnerDirectory (Join-Path $completeRoot 'repo-2') -OperationId $completeOperation -PackagePath $packageArchive).State PUBLISHED 'complete staging publish resume'
  $badFinalRoot=Join-Path $root 'bad-final-runners';New-Item -ItemType Directory -Path (Join-Path $badFinalRoot 'repo-3') -Force|Out-Null;New-Item -ItemType File -Path (Join-Path $badFinalRoot 'repo-3\partial.tmp')|Out-Null
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $badFinalRoot -TargetRunnerDirectory (Join-Path $badFinalRoot 'repo-3') -OperationId ([guid]::NewGuid().ToString('D')) -PackagePath $packageArchive} 'partial final runner root'
  $unknownRoot=Join-Path $root 'unknown-staging-runners';New-Item -ItemType Directory -Path (Join-Path $unknownRoot '.migration-staging\unknown-operation') -Force|Out-Null
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $unknownRoot -TargetRunnerDirectory (Join-Path $unknownRoot 'repo-4') -OperationId ([guid]::NewGuid().ToString('D')) -PackagePath $packageArchive} 'unknown staging authority'
  $incompleteSource=Join-Path $root 'incomplete-source';New-PackageTree $incompleteSource -Incomplete;$incompleteArchive=Join-Path $root 'incomplete.zip';Compress-Archive -Path (Join-Path $incompleteSource '*') -DestinationPath $incompleteArchive;$incompleteRoot=Join-Path $root 'incomplete-runners';New-Item -ItemType Directory -Path $incompleteRoot|Out-Null
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $incompleteRoot -TargetRunnerDirectory (Join-Path $incompleteRoot 'repo-5') -OperationId ([guid]::NewGuid().ToString('D')) -PackagePath $incompleteArchive} 'missing required runner package file'
  $reparseTarget=Join-Path $root 'reparse-target';New-Item -ItemType Directory -Path $reparseTarget|Out-Null;$reparseRoot=Join-Path $root 'reparse-runners';New-Item -ItemType Directory -Path $reparseRoot|Out-Null;$reparseOperation=[guid]::NewGuid().ToString('D');$reparseLink=Join-Path $reparseRoot ".migration-staging\$reparseOperation\runner";New-Item -ItemType Directory -Path (Split-Path -Parent $reparseLink) -Force|Out-Null
  $reparseCreated=$false;try{New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget -ErrorAction Stop|Out-Null;$reparseCreated=$true}catch{Write-Host 'runner staging reparse negative path unavailable on this host'}
  if($reparseCreated){
    Assert-Throws {Assert-Phase12BRunnerStagingAuthority -RunnerRoot $reparseRoot -OperationId $reparseOperation} 'reparse runner staging'
    $reparseFinalRoot=Join-Path $root 'reparse-final-runners';New-Item -ItemType Directory -Path $reparseFinalRoot|Out-Null;$reparseFinal=Join-Path $reparseFinalRoot 'repo-6';New-Item -ItemType Junction -Path $reparseFinal -Target $packageSource|Out-Null
    Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $reparseFinalRoot -TargetRunnerDirectory $reparseFinal -OperationId ([guid]::NewGuid().ToString('D')) -PackagePath $packageArchive} 'reparse final runner root'
  }

  # Runner ID/name are discovered from local metadata and must exactly match GitHub actual state.
  $otherLocal=[pscustomobject]@{agentId=77;agentName='another-runner';gitHubUrl='https://github.com/example/other-repo'}
  $otherGitHub=@([pscustomobject]@{id=77;name='another-runner';status='offline';busy=$false;labels=@(@('self-hosted','Windows','X64','codex-automation')|ForEach-Object{[pscustomobject]@{name=$_}})})
  $otherMatch=Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $otherLocal -CallerRepository 'example/other-repo' -CallerRepositoryId '999999999' -ActualRepositoryId '999999999' -GitHubRunners $otherGitHub -ExpectedLabels @('self-hosted','Windows','X64','codex-automation')
  if(-not $otherMatch.LocalRunnerMetadataExact -or -not $otherMatch.GitHubRunnerExact -or $otherMatch.RepositoryMismatch -or $otherMatch.RunnerIdMismatch -or $otherMatch.RunnerNameMismatch){throw 'generic runner identity was not accepted'}
  $repoMismatch=Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $otherLocal -CallerRepository 'example/other-repo' -CallerRepositoryId '999999999' -ActualRepositoryId '888888888' -GitHubRunners $otherGitHub -ExpectedLabels @('self-hosted','Windows','X64','codex-automation');if(-not $repoMismatch.RepositoryMismatch){throw 'repository ID mismatch accepted'}
  $urlMismatch=Copy-Object $otherLocal;$urlMismatch.gitHubUrl='https://github.com/example/wrong';$urlResult=Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $urlMismatch -CallerRepository 'example/other-repo' -CallerRepositoryId '999999999' -ActualRepositoryId '999999999' -GitHubRunners $otherGitHub -ExpectedLabels @('self-hosted','Windows','X64','codex-automation');if(-not $urlResult.RepositoryMismatch){throw '.runner repository URL mismatch accepted'}
  $idMismatch=Copy-Object $otherGitHub;$idMismatch[0].id=78;$idResult=Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $otherLocal -CallerRepository 'example/other-repo' -CallerRepositoryId '999999999' -ActualRepositoryId '999999999' -GitHubRunners $idMismatch -ExpectedLabels @('self-hosted','Windows','X64','codex-automation');if(-not $idResult.RunnerIdMismatch){throw 'runner ID mismatch accepted'}
  $nameMismatch=Copy-Object $otherGitHub;$nameMismatch[0].name='different-runner';$nameResult=Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $otherLocal -CallerRepository 'example/other-repo' -CallerRepositoryId '999999999' -ActualRepositoryId '999999999' -GitHubRunners $nameMismatch -ExpectedLabels @('self-hosted','Windows','X64','codex-automation');if(-not $nameResult.RunnerNameMismatch){throw 'runner name mismatch accepted'}
  $repositoryIdentityCases=@(
    @{Name='exact repository identity';IntentId='123';IntentName='example/repo';CallerId='123';CallerName='example/repo';ActualId='123';ActualName='example/repo';Read=$true;Exact=$true;Conflict=$false;Unknown=$false},
    @{Name='same name different GitHub ID';IntentId='123';IntentName='example/repo';CallerId='123';CallerName='example/repo';ActualId='456';ActualName='example/repo';Read=$true;Exact=$false;Conflict=$true;Unknown=$false},
    @{Name='caller desired-state changed';IntentId='123';IntentName='example/repo';CallerId='456';CallerName='example/repo';ActualId='456';ActualName='example/repo';Read=$true;Exact=$false;Conflict=$true;Unknown=$false},
    @{Name='stale intent';IntentId='123';IntentName='example/repo';CallerId='456';CallerName='example/repo';ActualId='123';ActualName='example/repo';Read=$true;Exact=$false;Conflict=$true;Unknown=$false},
    @{Name='GitHub repository read failure';IntentId='123';IntentName='example/repo';CallerId='123';CallerName='example/repo';ActualId='';ActualName='';Read=$false;Exact=$false;Conflict=$false;Unknown=$true},
    @{Name='malformed repository response';IntentId='123';IntentName='example/repo';CallerId='123';CallerName='example/repo';ActualId='not-an-id';ActualName='malformed';Read=$true;Exact=$false;Conflict=$false;Unknown=$true},
    @{Name='missing immutable repository ID';IntentId='123';IntentName='example/repo';CallerId='123';CallerName='example/repo';ActualId='';ActualName='example/repo';Read=$true;Exact=$false;Conflict=$false;Unknown=$true},
    @{Name='repository full name mismatch';IntentId='123';IntentName='example/repo';CallerId='123';CallerName='example/repo';ActualId='123';ActualName='example/recreated';Read=$true;Exact=$false;Conflict=$true;Unknown=$false}
  )
  foreach($case in $repositoryIdentityCases){
    $match=Get-Phase12BMigrationRepositoryIdentityMatch -IntentRepositoryId $case.IntentId -IntentRepositoryFullName $case.IntentName -CallerRepositoryId $case.CallerId -CallerRepositoryFullName $case.CallerName -ActualRepositoryId $case.ActualId -ActualRepositoryFullName $case.ActualName -ReadSucceeded $case.Read
    Assert-Equal $match.Exact $case.Exact "$($case.Name) exact"
    Assert-Equal $match.IdentityConflict $case.Conflict "$($case.Name) conflict"
    Assert-Equal $match.UnknownState $case.Unknown "$($case.Name) unknown"
  }
  $genericGuid=[guid]::NewGuid().ToString();$genericIdentity=[pscustomobject]@{OperationId=[guid]::NewGuid().ToString('D');RepositoryId='999999999';RepositoryFullName='example/other-repo';LegacyRunnerDirectory='D:\legacy-runner';LegacyRunnerId='77';LegacyRunnerName='another-runner';ExecutionAreaId=$genericGuid;TargetRunnerDirectory='D:\runners\repo-999999999';TargetRunnerName='codex-repo-999999999';PackageVersion=$packageVersion;PackageSha256=$packageSha}
  $genericRuntime=Join-Path $root 'generic-runtime';$genericIntent=Initialize-Phase12BMigrationIntent -RuntimeRoot $genericRuntime -Identity $genericIdentity
  Assert-Equal $genericIntent.execution_area_id $genericGuid 'generic execution area ID freeze';Assert-Equal $genericIntent.repository_id 999999999 'generic repository ID freeze';Assert-Equal $genericIntent.legacy_runner_name another-runner 'generic runner name freeze'

  $state=[pscustomobject]@{IdentityConflict=$false;UnknownState=$false;DispatchFenced=$false;Quiescent=$false;TargetHostPrepared=$false;PackageVerified=$false;ExecutionAreaIdPreserved=$true;AclExact=$false;LegacyRegistered=$true;TargetRegistered=$false;ServiceInstalled=$false;ServiceRunning=$false;ServiceExact=$false;ActiveExact=$false;LegacyDirectoryRetained=$true}
  $actions=[Collections.Generic.List[string]]::new();$stages=[Collections.Generic.List[string]]::new()
  $readState={Copy-Object $state}
  $mutate={param($name)[void]$actions.Add($name);switch($name){'FenceDispatch'{$state.DispatchFenced=$true}'WaitForQuiescence'{$state.Quiescent=$true}'PrepareTargetHost'{$state.TargetHostPrepared=$true;$state.PackageVerified=$true;$state.AclExact=$true}'UnregisterLegacy'{$state.LegacyRegistered=$false}'RegisterTarget'{$state.TargetRegistered=$true}'InstallService'{$state.ServiceInstalled=$true;$state.ServiceExact=$true}'StartService'{$state.ServiceRunning=$true}'WriteActiveMetadata'{$state.ActiveExact=$true}'RestoreDispatch'{$state.DispatchFenced=$false}}}
  $persist={param($stage,$ignored)[void]$stages.Add($stage)}
  $result=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage LEGACY_VERIFIED -ReadState $readState -Mutate $mutate -Persist $persist
  Assert-Equal $result.Stage MIGRATION_COMPLETE 'full migration lifecycle'
  foreach($action in @('FenceDispatch','WaitForQuiescence','PrepareTargetHost','UnregisterLegacy','RegisterTarget','InstallService','StartService','WriteActiveMetadata','RestoreDispatch')){if($actions -notcontains $action){throw "migration action missing: $action"}}

  # Every durable stage must resume through the same production decision function.
  $allStages=@('LEGACY_VERIFIED','DISPATCH_FENCED','QUIESCENT','TARGET_HOST_PREPARED','LEGACY_RUNNER_UNREGISTERING','LEGACY_RUNNER_UNREGISTERED','TARGET_RUNNER_REGISTERING','TARGET_RUNNER_REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','SERVICE_RUNNING','ACTIVE_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','MIGRATION_COMPLETE')
  foreach($start in $allStages){
    $state.DispatchFenced=$start -notin @('LEGACY_VERIFIED','DISPATCH_RESTORED','MIGRATION_COMPLETE');$state.Quiescent=$true;$state.TargetHostPrepared=$start -notin @('LEGACY_VERIFIED','DISPATCH_FENCED','QUIESCENT');$state.PackageVerified=$state.TargetHostPrepared;$state.AclExact=$state.TargetHostPrepared
    $state.LegacyRegistered=$start -in @('LEGACY_VERIFIED','DISPATCH_FENCED','QUIESCENT','TARGET_HOST_PREPARED','LEGACY_RUNNER_UNREGISTERING')
    $state.TargetRegistered=$start -in @('TARGET_RUNNER_REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','SERVICE_RUNNING','ACTIVE_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','MIGRATION_COMPLETE')
    $state.ServiceInstalled=$start -in @('SERVICE_INSTALLED','SERVICE_RUNNING','ACTIVE_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','MIGRATION_COMPLETE');$state.ServiceRunning=$start -in @('SERVICE_RUNNING','ACTIVE_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','MIGRATION_COMPLETE');$state.ServiceExact=$state.ServiceInstalled;$state.ActiveExact=$start -in @('ACTIVE_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','MIGRATION_COMPLETE')
    $resume=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage $start -ReadState $readState -Mutate $mutate -Persist $persist
    Assert-Equal $resume.Stage MIGRATION_COMPLETE "resume $start"
  }
  # Backward-compatible old crash window: dispatch restored before MIGRATION_COMPLETE persistence.
  $state.LegacyRegistered=$false;$state.TargetRegistered=$true;$state.ServiceInstalled=$true;$state.ServiceRunning=$true;$state.ServiceExact=$true;$state.ActiveExact=$true;$state.DispatchFenced=$false;$state.TargetHostPrepared=$true;$state.PackageVerified=$true;$state.AclExact=$true;$state.Quiescent=$true
  $actions.Clear();$legacyRestore=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage ACTIVE_VERIFIED -ReadState $readState -Mutate $mutate -Persist $persist
  Assert-Equal $legacyRestore.Stage MIGRATION_COMPLETE 'legacy post-restore crash window';if($actions -contains 'RestoreDispatch'){throw 'already restored dispatch was mutated again'}
  $actions.Clear();$restoringAlreadyDone=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage DISPATCH_RESTORING -ReadState $readState -Mutate $mutate -Persist $persist
  Assert-Equal $restoringAlreadyDone.Stage MIGRATION_COMPLETE 'restore success before stage persistence';if($actions -contains 'RestoreDispatch'){throw 'restored DISPATCH_RESTORING state repeated mutation'}
  $state.DispatchFenced=$true;$restoreFailureMutate={param($name)if($name -eq 'RestoreDispatch'){throw 'restore failed'}}
  Assert-Throws {Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage DISPATCH_RESTORING -ReadState $readState -Mutate $restoreFailureMutate -Persist $persist} 'dispatch restore failure'
  $readbackFailureMutate={param($name)if($name -ne 'RestoreDispatch'){throw "unexpected mutation $name"}}
  Assert-Throws {Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage DISPATCH_RESTORING -ReadState $readState -Mutate $readbackFailureMutate -Persist $persist} 'dispatch restore read-back failure'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage TARGET_RUNNER_REGISTERING -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$true;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$false})) MANUAL_INTERVENTION_REQUIRED 'dual registration'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage SERVICE_INSTALLED -Actual ([pscustomobject]@{IdentityConflict=$true;UnknownState=$false;LegacyRegistered=$false;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$false})) MANUAL_INTERVENTION_REQUIRED 'execution area identity change conflict'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage SERVICE_INSTALLED -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$false;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$true;SafeApprovedRecoveryCandidate=$false})) RESUME_SAFE 'post-mutation crash window'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage SERVICE_INSTALLED -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$false;TargetRegistered=$true;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$true})) RECOVER_WITH_APPROVAL 'bounded recovery candidate'
  Assert-Equal (Get-Phase12BMigrationRecoveryDecision -Stage '' -Actual ([pscustomobject]@{IdentityConflict=$false;UnknownState=$false;LegacyRegistered=$true;TargetRegistered=$false;PostconditionMatchesStage=$false;NextStagePostcondition=$false;SafeApprovedRecoveryCandidate=$false})) RETRY_SAFE 'pre-intent retry'

  # The entry point uses the same classifier and lifecycle; TestMode replaces only providers.
  $entry=Join-Path $root 'entry';New-Item -ItemType Directory -Path (Join-Path $entry 'callers'),(Join-Path $entry 'migrations'),(Join-Path $entry 'bin') -Force|Out-Null
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
if "%q%"==".migration_type" echo phase10-interactive
if "%q%"==".source.caller" echo caller
if "%q%"==".source.runner_directory" echo C:\codex-runner
if "%q%"==".package.version" echo 2.337.0
if "%q%"==".package.sha256" echo 1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc
'@.Replace('__EXEC__',$execution).Replace('__RUNNER__',$runnerRoot).Replace('__RUNTIME__',$entryRuntime).Replace('__PROFILE__',$profile)
  Set-Content -LiteralPath (Join-Path $entry 'bin\yq.cmd') -Value $yq -NoNewline
  $migration=Copy-Object $base
  foreach($property in @{schema=1;execution_area_id='545b497b-f7f6-4d44-90e3-544afa1bab4f';legacy_runner_id='21';legacy_runner_name='codex-automation-windows-01';workflow_dispatch_state='active';IdentityConflict=$false;UnknownState=$false;DispatchFenced=$false;Quiescent=$true;TargetHostPrepared=$false;PackageVerified=$false;ExecutionAreaIdPreserved=$true;AclExact=$false;LegacyRegistered=$true;TargetRegistered=$false;ServiceInstalled=$false;ServiceRunning=$false;ServiceExact=$false;ActiveExact=$false;LegacyDirectoryRetained=$true}.GetEnumerator()){$migration|Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value -Force}
  $migrationFile=Join-Path $entry 'migration.json';$migration|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $migrationFile -NoNewline
  $oldPath=$env:PATH;$env:PATH="$(Join-Path $entry 'bin');$oldPath"
  try{
    Assert-Throws {& (Join-Path $PSScriptRoot 'migrate-host.ps1') -PrivateConfig (Join-Path $entry 'environment.yaml') -Approve -TestMode -FixtureRoot $entry -MigrationReadbackFile $migrationFile|Out-Null} 'missing migration desired state'
    New-Item -ItemType File -Path (Join-Path $entry 'migrations\test-host.yaml')|Out-Null
    & (Join-Path $PSScriptRoot 'migrate-host.ps1') -PrivateConfig (Join-Path $entry 'environment.yaml') -Approve -TestMode -FixtureRoot $entry -MigrationReadbackFile $migrationFile|Out-Null
  }finally{$env:PATH=$oldPath}
  $entryState=Get-Content -LiteralPath $migrationFile -Raw|ConvertFrom-Json
  Assert-Equal (Read-Phase12BMigrationIntent $entryRuntime).migration_stage MIGRATION_COMPLETE 'entry point durable completion'
  Assert-Equal $entryState.workflow_dispatch_state active 'entry point restored dispatch'
  foreach($action in @('FenceDispatch','PrepareTargetHost','UnregisterLegacy','RegisterTarget','InstallService','StartService','WriteActiveMetadata','RestoreDispatch')){if(@($entryState.mutation_calls) -notcontains $action){throw "entry point provider action missing: $action"}}

  # Resume always revalidates intent, caller desired state, and GitHub actual repository identity before mutation.
  $entryIntent=Read-Phase12BMigrationIntent $entryRuntime
  $entryIdentity=[pscustomobject]@{OperationId=[string]$entryIntent.operation_id;RepositoryId='1338414331';RepositoryFullName='kusa07/interest-gacha';LegacyRunnerDirectory='C:\codex-runner';LegacyRunnerId='21';LegacyRunnerName='codex-automation-windows-01';ExecutionAreaId='545b497b-f7f6-4d44-90e3-544afa1bab4f';TargetRunnerDirectory=(Join-Path $runnerRoot 'repo-1338414331');TargetRunnerName='codex-repo-1338414331';PackageVersion=$packageVersion;PackageSha256=$packageSha}
  function Assert-EntryIdentityGuard([string]$guardStage,[bool]$legacyRegistered,[bool]$targetRegistered,[string]$actualId,[string]$actualName,[bool]$readError,[string]$label){
    Write-Phase12BMigrationIntent -RuntimeRoot $entryRuntime -Stage $guardStage -Identity $entryIdentity|Out-Null
    $guard=Copy-Object $entryState
    foreach($property in @{IdentityConflict=$false;UnknownState=$false;workflow_dispatch_state='disabled_manually';DispatchFenced=$true;Quiescent=$true;TargetHostPrepared=$true;PackageVerified=$true;ExecutionAreaIdPreserved=$true;AclExact=$true;LegacyRegistered=$legacyRegistered;TargetRegistered=$targetRegistered;ServiceInstalled=$false;ServiceRunning=$false;ServiceExact=$false;ActiveExact=$false;LegacyDirectoryRetained=$true;github_actual_repository_id=$actualId;github_actual_repository_full_name=$actualName;github_repository_read_error=$readError;mutation_calls=@()}.GetEnumerator()){$guard|Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value -Force}
    $guard|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $migrationFile -NoNewline
    Assert-Throws {& (Join-Path $PSScriptRoot 'migrate-host.ps1') -PrivateConfig (Join-Path $entry 'environment.yaml') -Approve -TestMode -FixtureRoot $entry -MigrationReadbackFile $migrationFile|Out-Null} $label
    $afterGuard=Get-Content -LiteralPath $migrationFile -Raw|ConvertFrom-Json
    if(@($afterGuard.mutation_calls).Count -ne 0){throw "$label performed a mutation before repository identity validation"}
  }
  Assert-EntryIdentityGuard -guardStage LEGACY_RUNNER_UNREGISTERING -legacyRegistered $true -targetRegistered $false -actualId '456' -actualName 'kusa07/interest-gacha' -readError $false -label 'pre-unregister same-name different-ID guard'
  Assert-EntryIdentityGuard -guardStage TARGET_RUNNER_REGISTERING -legacyRegistered $false -targetRegistered $false -actualId '456' -actualName 'kusa07/interest-gacha' -readError $false -label 'pre-register same-name different-ID guard'
  Assert-EntryIdentityGuard -guardStage SERVICE_INSTALLED -legacyRegistered $false -targetRegistered $true -actualId '' -actualName '' -readError $true -label 'resume repository read failure guard'

  'phase12b legacy host migration tests passed'
}finally{if(Test-Path Env:PHASE12B_TEST_ADAPTER){Remove-Item Env:PHASE12B_TEST_ADAPTER};if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
