[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PrivateConfig,[switch]$Approve,[switch]$TestMode,
    [string]$FixtureRoot,[string]$AdapterLog,[string]$ExternalReadbackFile,
    [string]$ServiceReadbackFile,[string]$MigrationReadbackFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
Test-Phase12BTestAdapter -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog -ExternalReadbackFile $ExternalReadbackFile -ServiceReadbackFile $ServiceReadbackFile -MigrationReadbackFile $MigrationReadbackFile
$cfg=Read-Phase12BConfig $PrivateConfig;$h=$cfg.Host
$hostState=Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root
if($hostState -eq 'EXISTING'){
    @('HOST_MIGRATION_PLAN','HOST_STATE=EXISTING','MIGRATION_SOURCE_STATE=CURRENT_MANAGED','MUTATIONS=NONE',("RESULT={0}" -f $(if($Approve){'VERIFY'}else{'PLAN'}))) -join "`n"
    if($Approve){foreach($managedCaller in $cfg.Callers){$verified=Invoke-Phase12BCallerRunner -Action Onboard -HostConfig $cfg.HostFile -RepositoryFullName $managedCaller.Repository -RepositoryId $managedCaller.RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot;if($verified.LifecycleAfter -ne 'ACTIVE'){throw 'Current managed caller migration failed.'}}}
    exit 0
}
$migration=$cfg.Migration
if($null -eq $migration){throw "Canonical migration desired state is missing: $($cfg.MigrationFile)"}
$LegacyRunnerDirectory=[IO.Path]::GetFullPath([string]$migration.SourceRunnerDirectory)
$legacyCallers=@($cfg.Callers|Where-Object{[string]$_.Name -ceq [string]$migration.SourceCaller})
if($legacyCallers.Count -ne 1){throw 'Canonical migration source caller is missing or ambiguous.'}
$caller=$legacyCallers[0]
$target=Get-Phase12BCallerRunnerIdentity -RunnerRoot $h.runner_root -RepositoryId $caller.RepositoryId
$package=Get-Phase12BRunnerPackageContract -Version $migration.PackageVersion -Sha256 $migration.PackageSha256

function Read-TestMigrationState {
    if(-not $MigrationReadbackFile){throw 'Legacy migration TestMode requires MigrationReadbackFile.'}
    $state=Get-Content -LiteralPath $MigrationReadbackFile -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if(-not $state.PSObject.Properties['schema'] -or [int]$state.schema -ne 1){throw 'Migration fixture schema is invalid.'}
    $state
}
function Write-TestMigrationState($State){$State|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $MigrationReadbackFile -NoNewline}
function Get-WorkflowApiPath { 'repos/{0}/actions/workflows/{1}' -f $caller.Repository,[uri]::EscapeDataString($caller.WorkflowPath) }
function Get-WorkflowDispatchState {
    if($TestMode){return [string](Read-TestMigrationState).workflow_dispatch_state}
    $raw=& gh api (Get-WorkflowApiPath) 2>$null;if($LASTEXITCODE -ne 0){throw 'Workflow dispatch-state read-back failed.'}
    $workflow=$raw|ConvertFrom-Json -ErrorAction Stop
    if([string]$workflow.state -notin @('active','disabled_manually')){throw 'Workflow dispatch state is unknown.'}
    [string]$workflow.state
}
function Get-TrustedWorkflowState {
    if($TestMode){return [string](Read-TestMigrationState).workflow_state}
    $bash='C:\Program Files\Git\bin\bash.exe';if(-not(Test-Path -LiteralPath $bash -PathType Leaf)){throw 'Fixed Git Bash is unavailable.'}
    $script=Join-Path $PSScriptRoot '..\onboarding\sync-caller-workflow.sh'
    $output=& $bash $script --repository $caller.Repository --environment $cfg.Environment --private-config $caller.Path --target-workflow-sha $cfg.EnvironmentData.active_workflow_sha --mode plan 2>&1
    if($LASTEXITCODE -ne 0){throw "Trusted workflow classification failed: $($output -join ' ')"}
    $line=@($output|Where-Object{$_ -match '^WORKFLOW_STATE='});if($line.Count -ne 1){throw 'Trusted workflow classification is missing.'}
    ($line[0] -split '=',2)[1]
}
function Get-LegacySourceObservation {
    if($TestMode){return Read-TestMigrationState}
    $executionInspect=$false;$executionPreflight=$false
    try{& (Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1') -Action inspect -Root $h.execution_root|Out-Null;$executionInspect=$true}catch{}
    try{& (Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1') -Action preflight -Root $h.execution_root|Out-Null;$executionPreflight=$true}catch{}
    $marker=$null;try{$marker=Get-Content -LiteralPath (Join-Path $h.execution_root '.codex-automation-managed') -Raw|ConvertFrom-Json -ErrorAction Stop}catch{}
    $executionId=if($marker){[string]$marker.execution_area_id}else{''}
    $executionGuid=[guid]::Empty;$executionIdValid=[guid]::TryParse($executionId,[ref]$executionGuid)
    $legacySafe=(Test-Path -LiteralPath $LegacyRunnerDirectory -PathType Container) -and (Test-Phase12BNoReparse $LegacyRunnerDirectory)
    $runner=$null
    if($legacySafe){try{$runner=Get-Content -LiteralPath (Join-Path $LegacyRunnerDirectory '.runner') -Raw|ConvertFrom-Json -ErrorAction Stop}catch{}}
    $filesExact=$legacySafe -and @('config.cmd','run.cmd','.runner','bin\Runner.Listener.exe'|Where-Object{-not(Test-Path -LiteralPath (Join-Path $LegacyRunnerDirectory $_) -PathType Leaf)}).Count -eq 0
    $repoRaw=& gh api "repos/$($caller.Repository)" 2>$null;if($LASTEXITCODE -ne 0){throw 'GitHub repository read-back failed.'}
    $actualRepository=$repoRaw|ConvertFrom-Json -ErrorAction Stop
    $ghRaw=& gh api "repos/$($caller.Repository)/actions/runners?per_page=100" 2>$null;if($LASTEXITCODE -ne 0){throw 'GitHub runner read-back failed.'}
    $runnerResponse=$ghRaw|ConvertFrom-Json -ErrorAction Stop
    if([int]$runnerResponse.total_count -gt 100){throw 'GitHub runner read-back is incomplete; pagination is required.'}
    $gh=@($runnerResponse.runners)
    $identityMatch=if($runner){Get-Phase12BLegacyRunnerIdentityMatch -LocalRunner $runner -CallerRepository $caller.Repository -CallerRepositoryId $caller.RepositoryId -ActualRepositoryId ([string]$actualRepository.id) -GitHubRunners $gh -ExpectedLabels $h.labels}else{$null}
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object{[string]$_.PathName -like "*$LegacyRunnerDirectory*"})
    $runnerProcesses=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{[string]$_.ExecutablePath -like "$LegacyRunnerDirectory*"})
    $codexProcesses=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{[string]$_.ExecutablePath -like "$($h.execution_root)*" -or [string]$_.CommandLine -like "*$($h.execution_root)*"})
    $credentialResidue=@(Get-ChildItem -LiteralPath $h.execution_root -Recurse -Force -File -ErrorAction Stop|Where-Object{$_.Name -in @('auth.json','credentials.json')}).Count -gt 0
    $current=Read-Phase12BCurrentRunState -Path (Join-Path $h.execution_root 'state\current-run.json')
    $mutex=Get-Phase12BExecutionMutexState -ExecutionRoot $h.execution_root
    $residual=Get-Phase12BResidualState -ExecutionRoot $h.execution_root -RepositoryFullName $caller.Repository
    $jobs=Get-Phase12BGitHubActiveJobCount -RepositoryFullName $caller.Repository
    $targetRootsAbsent=@(@($h.runtime_root,$h.runner_root,$h.profile_root)|Where-Object{Test-Path -LiteralPath $_}).Count -eq 0
    [pscustomobject]@{
        schema=1;HostState=$hostState;CurrentManagedExact=($hostState -eq 'EXISTING');IdentityConflict=$false;DuplicateGitHubRunner=($null -eq $identityMatch -or [bool]$identityMatch.DuplicateGitHubRunner);UnexpectedService=($services.Count -gt 0);RepositoryMismatch=($null -eq $identityMatch -or [bool]$identityMatch.RepositoryMismatch);RunnerNameMismatch=($null -eq $identityMatch -or [bool]$identityMatch.RunnerNameMismatch);RunnerIdMismatch=($null -eq $identityMatch -or [bool]$identityMatch.RunnerIdMismatch)
        ExecutionRootPresent=(Test-Path -LiteralPath $h.execution_root -PathType Container);ExecutionInspect=$executionInspect;ExecutionPreflight=$executionPreflight;ExecutionAreaIdExact=$executionIdValid;execution_area_id=$executionId;CurrentRunState=$current.State;MutexState=$mutex;ResidualClean=(-not $residual.OwnershipUnknown -and $residual.TargetCount -eq 0 -and -not $residual.SharedResidualPresent);CredentialResidue=$credentialResidue;RelevantProcessCount=$codexProcesses.Count
        LegacyRunnerPresent=$legacySafe;LegacyRunnerSafe=$legacySafe;LegacyRunnerFilesExact=$filesExact;LocalRunnerMetadataExact=($null -ne $identityMatch -and [bool]$identityMatch.LocalRunnerMetadataExact);legacy_runner_id=if($identityMatch){[string]$identityMatch.LegacyRunnerId}else{''};legacy_runner_name=if($identityMatch){[string]$identityMatch.LegacyRunnerName}else{''};GitHubRunnerCount=if($identityMatch){[int]$identityMatch.GitHubRunnerCount}else{0};GitHubRunnerExact=($null -ne $identityMatch -and [bool]$identityMatch.GitHubRunnerExact);GitHubRunnerStatus=if($identityMatch){[string]$identityMatch.GitHubRunnerStatus}else{'unknown'};GitHubRunnerBusy=if($identityMatch){[bool]$identityMatch.GitHubRunnerBusy}else{$true};ActiveGitHubJobCount=$jobs
        LegacyServicePresent=($services.Count -gt 0);RunnerProcessCount=$runnerProcesses.Count;TargetRootsAbsent=$targetRootsAbsent;WorkflowState=(Get-TrustedWorkflowState);workflow_dispatch_state=(Get-WorkflowDispatchState);DispatchInitiallyActive=((Get-WorkflowDispatchState) -eq 'active')
    }
}
function Get-MigrationRepositoryIdentityState($FixtureState) {
    $readSucceeded=$false;$actualRepositoryId='';$actualRepositoryFullName=''
    if($TestMode){
        $state=if($null -ne $FixtureState){$FixtureState}else{Read-TestMigrationState}
        $readSucceeded=-not($state.PSObject.Properties['github_repository_read_error'] -and [bool]$state.github_repository_read_error)
        if($state.PSObject.Properties['github_actual_repository_id']){$actualRepositoryId=[string]$state.github_actual_repository_id}
        if($state.PSObject.Properties['github_actual_repository_full_name']){$actualRepositoryFullName=[string]$state.github_actual_repository_full_name}
    } else {
        try {
            $repoRaw=& gh api "repos/$($identity.RepositoryFullName)" 2>$null
            if($LASTEXITCODE -ne 0){throw 'repository query failed'}
            $actualRepository=$repoRaw|ConvertFrom-Json -ErrorAction Stop
            if($actualRepository.PSObject.Properties['id']){$actualRepositoryId=[string]$actualRepository.id}
            if($actualRepository.PSObject.Properties['full_name']){$actualRepositoryFullName=[string]$actualRepository.full_name}
            $readSucceeded=$true
        } catch {
            $readSucceeded=$false
        }
    }
    Get-Phase12BMigrationRepositoryIdentityMatch `
        -IntentRepositoryId ([string]$identity.RepositoryId) `
        -IntentRepositoryFullName ([string]$identity.RepositoryFullName) `
        -CallerRepositoryId ([string]$caller.RepositoryId) `
        -CallerRepositoryFullName ([string]$caller.Repository) `
        -ActualRepositoryId $actualRepositoryId `
        -ActualRepositoryFullName $actualRepositoryFullName `
        -ReadSucceeded $readSucceeded
}
function Get-ActualMigrationState {
    if($TestMode){
        $state=Read-TestMigrationState
        $repositoryIdentity=Get-MigrationRepositoryIdentityState $state
        $state|Add-Member -NotePropertyName IdentityConflict -NotePropertyValue ([bool]$state.IdentityConflict -or [bool]$repositoryIdentity.IdentityConflict) -Force
        $state|Add-Member -NotePropertyName UnknownState -NotePropertyValue ([bool]$state.UnknownState -or [bool]$repositoryIdentity.UnknownState) -Force
        $state|Add-Member -NotePropertyName ActualRepositoryId -NotePropertyValue ([string]$repositoryIdentity.ActualRepositoryId) -Force
        $state|Add-Member -NotePropertyName ActualRepositoryFullName -NotePropertyValue ([string]$repositoryIdentity.ActualRepositoryFullName) -Force
        return $state
    }
    $repositoryIdentity=Get-MigrationRepositoryIdentityState
    $ghRaw=& gh api "repos/$($caller.Repository)/actions/runners?per_page=100" 2>$null;if($LASTEXITCODE -ne 0){throw 'GitHub runner read-back failed.'};$runners=@(($ghRaw|ConvertFrom-Json -ErrorAction Stop).runners)
    $legacy=@($runners|Where-Object{[string]$_.id -eq [string]$identity.LegacyRunnerId -and [string]$_.name -ceq [string]$identity.LegacyRunnerName})
    $canonical=@($runners|Where-Object{[string]$_.name -ceq [string]$identity.TargetRunnerName})
    $legacyLabels=if($legacy.Count -eq 1){@($legacy[0].labels|ForEach-Object{[string]$_.name})}else{@()}
    $expectedLabels=@('self-hosted','Windows','X64','codex-automation');$targetLabels=if($canonical.Count -eq 1){@($canonical[0].labels|ForEach-Object{[string]$_.name})}else{@()}
    $legacyExact=$legacy.Count -eq 1 -and @(Compare-Object ($expectedLabels|Sort-Object) ($legacyLabels|Sort-Object -Unique)).Count -eq 0 -and [string]$legacy[0].status -eq 'offline' -and -not[bool]$legacy[0].busy
    $targetExact=$canonical.Count -eq 1 -and @(Compare-Object ($expectedLabels|Sort-Object) ($targetLabels|Sort-Object -Unique)).Count -eq 0
    $targetOnline=$targetExact -and [string]$canonical[0].status -eq 'online' -and -not[bool]$canonical[0].busy
    $service=Get-Phase12BServiceForRunner -RunnerRoot $identity.TargetRunnerDirectory
    $runtime=Read-Phase12BRuntime $h.runtime_root
    $metadata=Read-Phase12BRunnerMetadata -RuntimeRoot $h.runtime_root -RepositoryId $caller.RepositoryId -RepositoryFullName $caller.Repository -RunnerRoot $h.runner_root
    $area=$null;try{$area=Get-Content -LiteralPath (Join-Path $h.execution_root '.codex-automation-managed') -Raw|ConvertFrom-Json}catch{}
    $executionAreaPreserved=$area -and [string]$area.execution_area_id -ceq [string]$identity.ExecutionAreaId
    $aclExact=$true;foreach($root in @($h.runtime_root,$h.profile_root,$h.execution_root,$h.runner_root)){if(-not(Test-Path -LiteralPath $root) -or -not(Test-Phase12BAclPolicy -Acl (Get-Acl -LiteralPath $root))){$aclExact=$false}}
    $packageOk=Test-Phase12BRunnerPackage -Path $h.runner_package_path -ExpectedSha256 $identity.PackageSha256
    $hostPrepared=$runtime -and (Test-Path -LiteralPath (Join-Path $identity.TargetRunnerDirectory 'config.cmd') -PathType Leaf)
    $serviceExact=$service.Classification -eq 'EXISTING'
    $serviceRunning=$serviceExact -and [string]$service.State -eq 'Running'
    $activeExact=$metadata -and [string]$metadata.lifecycle_state -eq 'ACTIVE' -and $targetOnline -and $serviceRunning -and (Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root) -eq 'EXISTING'
    $identityConflict=[bool]$repositoryIdentity.IdentityConflict -or $legacy.Count -gt 1 -or $canonical.Count -gt 1 -or ($legacy.Count -eq 1 -and $canonical.Count -eq 1) -or ($legacy.Count -eq 1 -and -not $legacyExact) -or ($canonical.Count -eq 1 -and -not $targetExact) -or -not $executionAreaPreserved
    [pscustomobject]@{IdentityConflict=$identityConflict;UnknownState=[bool]$repositoryIdentity.UnknownState;ActualRepositoryId=[string]$repositoryIdentity.ActualRepositoryId;ActualRepositoryFullName=[string]$repositoryIdentity.ActualRepositoryFullName;DispatchFenced=((Get-WorkflowDispatchState) -eq 'disabled_manually');Quiescent=((Wait-Phase12BCallerQuiescence -ExecutionRoot $h.execution_root -RepositoryId $caller.RepositoryId -RepositoryFullName $caller.Repository -TimeoutSeconds 0).Result -eq 'PASS');TargetHostPrepared=[bool]$hostPrepared;PackageVerified=$packageOk;ExecutionAreaIdPreserved=$executionAreaPreserved;AclExact=$aclExact;LegacyRegistered=$legacyExact;TargetRegistered=$targetExact;ServiceInstalled=$serviceExact;ServiceRunning=$serviceRunning;ServiceExact=$serviceExact;ActiveExact=[bool]$activeExact;LegacyDirectoryRetained=(Test-Path -LiteralPath $identity.LegacyRunnerDirectory -PathType Container)}
}
function Assert-OfficialRunnerPackageProvenance {
    if($TestMode){return}
    $releaseRaw=& gh api $package.ReleaseApiPath 2>$null
    if($LASTEXITCODE -ne 0){throw 'Official runner release metadata read-back failed.'}
    try{$release=$releaseRaw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Official runner release metadata is malformed.'}
    if(-not(Test-Phase12BRunnerReleaseAsset -Contract $package -Release $release)){throw 'Official runner package provenance or asset digest verification failed.'}
}
function Invoke-MigrationMutation([string]$Name){
    if($TestMode){$s=Read-TestMigrationState;$calls=@(if($s.PSObject.Properties['mutation_calls']){$s.mutation_calls});$calls+=$Name;$s|Add-Member -NotePropertyName mutation_calls -NotePropertyValue $calls -Force;switch($Name){'FenceDispatch'{$s.workflow_dispatch_state='disabled_manually';$s.DispatchFenced=$true}'WaitForQuiescence'{$s.Quiescent=$true}'PrepareTargetHost'{$s.TargetHostPrepared=$true;$s.PackageVerified=$true;$s.ExecutionAreaIdPreserved=$true;$s.AclExact=$true}'UnregisterLegacy'{$s.LegacyRegistered=$false}'RegisterTarget'{$s.TargetRegistered=$true}'InstallService'{$s.ServiceInstalled=$true;$s.ServiceExact=$true}'StartService'{$s.ServiceRunning=$true}'WriteActiveMetadata'{$s.ActiveExact=$true}'RestoreDispatch'{$s.workflow_dispatch_state='active';$s.DispatchFenced=$false}};Write-TestMigrationState $s;return}
    switch($Name){
      'FenceDispatch'{& gh api --method PUT ((Get-WorkflowApiPath)+'/disable')|Out-Null;if($LASTEXITCODE -ne 0){throw 'Workflow dispatch fence failed.'}}
      'WaitForQuiescence'{$quiet=Wait-Phase12BCallerQuiescence -ExecutionRoot $h.execution_root -RepositoryId $caller.RepositoryId -RepositoryFullName $caller.Repository -TimeoutSeconds ([int]$h.quiescence_timeout_seconds);if($quiet.Result -ne 'PASS'){throw "Migration quiescence failed: $($quiet.Detail)"}}
      'PrepareTargetHost'{
        Assert-OfficialRunnerPackageProvenance
        foreach($root in @($h.profile_root,$h.runner_root)){New-Item -ItemType Directory -Path $root -Force|Out-Null}
        foreach($root in @($h.runtime_root,$h.profile_root,$h.execution_root,$h.runner_root)){Invoke-Phase12BAction -Name ApplyAcl -Argument $root}
        $packageDirectory=Split-Path -Parent $h.runner_package_path
        foreach($directory in @((Join-Path $h.runtime_root 'migration'),$packageDirectory,$identity.TargetRunnerDirectory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null;Invoke-Phase12BAction -Name ApplyAcl -Argument $directory}
        $runtimeJson=@{schema=1;host_id=$h.host_id;service_identity='NT AUTHORITY\NETWORK SERVICE';service_sid='S-1-5-20';execution_root=$h.execution_root;runtime_root=$h.runtime_root}|ConvertTo-Json -Compress
        Invoke-Phase12BAction -Name WriteRuntime -Argument (Join-Path $h.runtime_root 'runtime.json') -RuntimeJson $runtimeJson
        if(-not(Test-Path -LiteralPath $h.runner_package_path -PathType Leaf)){$tmp=$h.runner_package_path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';try{Invoke-WebRequest -Uri $package.Uri -OutFile $tmp -UseBasicParsing;if(-not(Test-Phase12BRunnerPackage $tmp -ExpectedSha256 $package.Sha256)){throw 'Runner package checksum verification failed.'};[IO.File]::Move($tmp,$h.runner_package_path)}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}}
        if(-not(Test-Phase12BRunnerPackage $h.runner_package_path -ExpectedSha256 $package.Sha256)){throw 'Runner package checksum verification failed.'}
        if(-not(Test-Path -LiteralPath (Join-Path $identity.TargetRunnerDirectory 'config.cmd') -PathType Leaf)){& (Join-Path $PSScriptRoot 'runner-adapter.ps1') -Action InstallPackage -RunnerRoot $identity.TargetRunnerDirectory -Repository $caller.Repository -RepositoryId $caller.RepositoryId -RunnerPackagePath $h.runner_package_path|Out-Null}
      }
      'UnregisterLegacy'{& (Join-Path $PSScriptRoot 'runner-adapter.ps1') -Action Unregister -RunnerRoot $identity.LegacyRunnerDirectory -Repository $caller.Repository -RepositoryId $caller.RepositoryId|Out-Null}
      'RegisterTarget'{& (Join-Path $PSScriptRoot 'runner-adapter.ps1') -Action Register -RunnerRoot $identity.TargetRunnerDirectory -Repository $caller.Repository -RepositoryId $caller.RepositoryId|Out-Null}
      'InstallService'{& (Join-Path $PSScriptRoot 'runner-adapter.ps1') -Action InstallService -RunnerRoot $identity.TargetRunnerDirectory -Repository $caller.Repository -RepositoryId $caller.RepositoryId|Out-Null}
      'StartService'{& (Join-Path $PSScriptRoot 'runner-adapter.ps1') -Action StartService -RunnerRoot $identity.TargetRunnerDirectory -Repository $caller.Repository -RepositoryId $caller.RepositoryId|Out-Null}
      'WriteActiveMetadata'{Write-Phase12BRunnerMetadata -RuntimeRoot $h.runtime_root -RepositoryId $caller.RepositoryId -RepositoryFullName $caller.Repository -RunnerRoot $h.runner_root -LifecycleState ACTIVE -ServiceName (Get-Phase12BExpectedServiceName $identity.TargetRunnerDirectory)|Out-Null}
      'RestoreDispatch'{& gh api --method PUT ((Get-WorkflowApiPath)+'/enable')|Out-Null;if($LASTEXITCODE -ne 0){throw 'Workflow dispatch restoration failed.'}}
      default{throw "Unknown migration mutation: $Name"}
    }
}

Assert-OfficialRunnerPackageProvenance
$intent=Read-Phase12BMigrationIntent -RuntimeRoot $h.runtime_root
if($intent){
    $identity=[pscustomobject]@{RepositoryId=[string]$intent.repository_id;RepositoryFullName=[string]$intent.repository_full_name;LegacyRunnerDirectory=[string]$intent.legacy_runner_directory;LegacyRunnerId=[string]$intent.legacy_runner_id;LegacyRunnerName=[string]$intent.legacy_runner_name;ExecutionAreaId=[string]$intent.execution_area_id;TargetRunnerDirectory=[string]$intent.target_runner_directory;TargetRunnerName=[string]$intent.target_runner_name;PackageVersion=[string]$intent.package_version;PackageSha256=[string]$intent.package_sha256}
    if($identity.RepositoryId -cne [string]$caller.RepositoryId -or $identity.RepositoryFullName -cne [string]$caller.Repository -or $identity.LegacyRunnerDirectory -cne $LegacyRunnerDirectory -or $identity.TargetRunnerDirectory -cne [string]$target.RunnerDirectory -or $identity.TargetRunnerName -cne [string]$target.RunnerName -or $identity.PackageVersion -cne [string]$package.Version -or $identity.PackageSha256 -cne [string]$package.Sha256){throw 'Migration intent contradicts desired immutable identity.'}
    $sourceState='LEGACY_PHASE10_INTERACTIVE';$stage=[string]$intent.migration_stage
} else {
    $source=Get-LegacySourceObservation;$sourceState=Get-Phase12BMigrationSourceState $source
    $identity=[pscustomobject]@{RepositoryId=[string]$caller.RepositoryId;RepositoryFullName=[string]$caller.Repository;LegacyRunnerDirectory=$LegacyRunnerDirectory;LegacyRunnerId=[string]$source.legacy_runner_id;LegacyRunnerName=[string]$source.legacy_runner_name;ExecutionAreaId=[string]$source.execution_area_id;TargetRunnerDirectory=[string]$target.RunnerDirectory;TargetRunnerName=[string]$target.RunnerName;PackageVersion=[string]$package.Version;PackageSha256=[string]$package.Sha256}
    $stage='NOT_STARTED'
}
if($intent){$actualForPlan=Get-ActualMigrationState;$quiescence=[bool]$actualForPlan.Quiescent;$recovery=if(Test-Phase12BMigrationStageTopology -Stage $stage -Actual $actualForPlan){'RESUME_SAFE'}else{'MANUAL_INTERVENTION_REQUIRED'}}else{$quiescence=[string]$source.CurrentRunState -eq 'ABSENT' -and [string]$source.MutexState -eq 'FREE' -and [int]$source.ActiveGitHubJobCount -eq 0;$recovery=if($sourceState -eq 'LEGACY_PHASE10_INTERACTIVE'){'RETRY_SAFE'}else{'MANUAL_INTERVENTION_REQUIRED'}}
@('HOST_MIGRATION_PLAN',"HOST_STATE=$hostState","MIGRATION_SOURCE_STATE=$sourceState","EXECUTION_AREA_ID=$($identity.ExecutionAreaId)","LEGACY_RUNNER_DIRECTORY=$($identity.LegacyRunnerDirectory)","LEGACY_RUNNER_ID=$($identity.LegacyRunnerId)","LEGACY_RUNNER_NAME=$($identity.LegacyRunnerName)","REPOSITORY_ID=$($identity.RepositoryId)","TARGET_RUNNER_DIRECTORY=$($identity.TargetRunnerDirectory)","TARGET_RUNNER_NAME=$($identity.TargetRunnerName)",'TARGET_SERVICE_IDENTITY=NT AUTHORITY\NETWORK SERVICE','TARGET_SERVICE_MODE=official-github-runner-service',"QUIESCENT=$quiescence","PACKAGE_VERSION=$($package.Version)","PACKAGE_URI=$($package.Uri)","PACKAGE_SHA256=$($package.Sha256)","MIGRATION_STAGE=$stage","RECOVERY_DECISION=$recovery",'LEGACY_DIRECTORY_RETENTION=REQUIRED','APPROVAL_REQUIRED=true',("RESULT={0}" -f $(if($Approve){'APPLY'}else{'PLAN'}))) -join "`n"
if(-not $Approve){exit 0}
if($sourceState -ne 'LEGACY_PHASE10_INTERACTIVE'){throw "Migration source is not automatically supported: $sourceState"}
if($recovery -eq 'MANUAL_INTERVENTION_REQUIRED'){throw 'Migration stage and actual topology require manual intervention.'}
if(-not $intent){$intent=Initialize-Phase12BMigrationIntent -RuntimeRoot $h.runtime_root -Identity $identity;$stage='LEGACY_VERIFIED'}
$readState={Get-ActualMigrationState}
$mutate={param($name)Invoke-MigrationMutation $name}
$persist={param($newStage,$id)Write-Phase12BMigrationIntent -RuntimeRoot $h.runtime_root -Stage $newStage -Identity $id|Out-Null}
$result=Invoke-Phase12BMigrationLifecycle -Identity $identity -InitialStage $stage -ReadState $readState -Mutate $mutate -Persist $persist
if($result.Stage -ne 'MIGRATION_COMPLETE'){throw 'Migration did not reach its exact final state.'}
'MIGRATE_APPLY=PASS'
