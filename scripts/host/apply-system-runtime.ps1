[CmdletBinding()]
param([Parameter(Mandatory)][string]$PrivateConfig, [switch]$Approve, [switch]$TestMode, [string]$FixtureRoot, [string]$RuntimeReadbackFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'phase12b-system-runtime.psm1') -Force
Test-Phase12BTestAdapter -TestMode:$TestMode -FixtureRoot $FixtureRoot
if($TestMode){
    $fullFixture=Assert-Phase12BFixtureRoot $FixtureRoot
    if([string]::IsNullOrWhiteSpace($RuntimeReadbackFile)){throw 'TestMode requires runtime read-back fixture.'}
    $fullReadback=[IO.Path]::GetFullPath($RuntimeReadbackFile)
    if(-not $fullReadback.StartsWith($fullFixture.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $fullReadback -PathType Leaf) -or -not(Test-Phase12BNoReparse $fullReadback)){throw 'Runtime read-back fixture is unsafe.'}
} elseif($RuntimeReadbackFile){throw 'Runtime fixture injection is prohibited in Production.'}

$cfg = Read-Phase12BConfig $PrivateConfig
$h = $cfg.Host
$hostState = Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root
if ($hostState -ne 'EXISTING') { throw "System runtime apply requires an exact managed host: $hostState" }
if (@($cfg.Callers).Count -ne 1) { throw 'System runtime apply currently requires exactly one managed caller; multi-caller Service refresh is unsupported.' }
$caller = $cfg.Callers[0]
$identity = Get-Phase12BCallerRunnerIdentity -RunnerRoot $h.runner_root -RepositoryId $caller.RepositoryId
$intentDirectory = Join-Path $h.runtime_root 'system-runtime'
$intentPath = Join-Path $intentDirectory 'powershell7-intent.json'
$policy = Get-Phase12BSystemRuntimePolicy
$script:expectedRunnerId = '0'
$packagePath = Join-Path (Join-Path $intentDirectory 'packages') $policy.Asset
$workflowApi = 'repos/{0}/actions/workflows/{1}' -f $caller.Repository,[uri]::EscapeDataString($caller.WorkflowPath)
function Read-FixtureState {
    try{$fixture=Get-Content -LiteralPath $RuntimeReadbackFile -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Runtime read-back fixture is malformed.'}
    if([string]$fixture.schema -ne '1' -or -not $fixture.PSObject.Properties['runtime_observation']){throw 'Runtime read-back fixture schema is invalid.'}
    $required=@('repository_id','repository_full_name','runner_id','runner_name','runner_online_idle','service_name','service_identity','service_state','workflow_exact','dispatch_state','quiescent','quiescence_reason','package_verified','unknown_state','fail_action')
    foreach($name in $required){if(-not $fixture.PSObject.Properties[$name]){throw "Runtime fixture is missing $name."}}
    foreach($name in @('runner_online_idle','workflow_exact','quiescent','package_verified','unknown_state')){if($fixture.$name -isnot [bool]){throw "Runtime fixture $name must be Boolean."}}
    $fixture
}
function Write-FixtureState($Fixture){$Fixture|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $RuntimeReadbackFile -NoNewline}

function Get-DispatchState {
    $raw = & gh api $workflowApi 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Workflow dispatch read-back failed.' }
    try { $value = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Workflow dispatch read-back is malformed.' }
    if ([string]$value.state -notin @('active','disabled_manually')) { throw 'Workflow dispatch state is unsupported.' }
    [string]$value.state
}
function Test-TrustedWorkflow {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { return $false }
    $sync = Join-Path $PSScriptRoot '..\onboarding\sync-caller-workflow.sh'
    $result = & $bash $sync --repository $caller.Repository --environment $cfg.Environment --private-config $caller.Path --target-workflow-sha $cfg.EnvironmentData.active_workflow_sha --mode plan 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    $values = @($result | Where-Object { $_ -match '^WORKFLOW_STATE=' })
    return $values.Count -eq 1 -and [string]$values[0] -ceq 'WORKFLOW_STATE=EXACT_TARGET'
}
function Get-ActualState {
    if($TestMode){
        $fixture=Read-FixtureState
        $runtime=Get-Phase12BSystemRuntimeState -Observation $fixture.runtime_observation
        $repositoryExact=[string]$fixture.repository_id -ceq [string]$caller.RepositoryId -and [string]$fixture.repository_full_name -ceq [string]$caller.Repository
        $runnerExact=[string]$fixture.runner_name -ceq [string]$identity.RunnerName -and [string]$fixture.runner_id -match '^[1-9][0-9]*$'
        $serviceExact=[string]$fixture.service_name -ieq [string]$identity.ServiceName -and [string]$fixture.service_identity -in @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')
        return [pscustomobject]@{
            HostState=$hostState;CallerExact=$repositoryExact;RepositoryIdentityExact=$repositoryExact;IdentityExact=($repositoryExact -and $runnerExact -and [string]$fixture.runner_id -ceq [string]$script:expectedRunnerId)
            RunnerIdentityExact=($repositoryExact -and $runnerExact);RunnerId=[string]$fixture.runner_id;RunnerOnlineIdle=[bool]$fixture.runner_online_idle
            ServiceExact=$serviceExact;ServiceState=[string]$fixture.service_state;WorkflowExact=[bool]$fixture.workflow_exact;DispatchState=[string]$fixture.dispatch_state
            Quiescent=([bool]$fixture.quiescent -and [string]$fixture.quiescence_reason -ceq 'NO_CURRENT_EXECUTION');RuntimeClassification=$runtime.Classification;MachinePath=$runtime.MachinePath;PackageVerified=[bool]$fixture.package_verified;UnknownState=[bool]$fixture.unknown_state
        }
    }
    $runtime = Get-Phase12BSystemRuntimeState
    $service = Get-Phase12BServiceForRunner -RunnerRoot $identity.RunnerDirectory
    $repository = Get-Phase12BGitHubRepositoryMetadata -Repository $caller.Repository -GhPath (Get-Command gh -ErrorAction Stop).Source
    $runners = Get-Phase12BGitHubRunnerList -Repository $caller.Repository
    $matching = @($runners.Runners | Where-Object { [string]$_.name -ceq $identity.RunnerName })
    $expectedLabels = @($h.labels | Sort-Object -Unique)
    $actualLabels = @()
    if ($matching.Count -eq 1) { $actualLabels = @($matching[0].labels | ForEach-Object { [string]$_.name } | Sort-Object -Unique) }
    $labelsExact = $matching.Count -eq 1 -and @(Compare-Object $expectedLabels $actualLabels).Count -eq 0
    $idExact = [string]$repository.id -ceq [string]$caller.RepositoryId -and [string]$repository.full_name -ceq [string]$caller.Repository
    $registrationId = if ($matching.Count -eq 1) { [string]$matching[0].id } else { '' }
    $serviceExact = $service.Classification -eq 'EXISTING' -and [string]$service.ServiceName -ieq [string]$identity.ServiceName -and [string]$service.Identity -in @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')
    $quiet = Wait-Phase12BCallerQuiescence -ExecutionRoot $h.execution_root -RepositoryId $caller.RepositoryId -RepositoryFullName $caller.Repository -TimeoutSeconds 0
    $packageVerified = (Test-Path -LiteralPath $packagePath -PathType Leaf) -and (Test-Phase12BNoReparse $packagePath)
    if ($packageVerified) { $packageVerified = [string](Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -ieq $policy.Sha256 -and (Test-Phase12BMicrosoftSignature $packagePath) }
    [pscustomobject]@{
        HostState=$hostState; CallerExact=$idExact; RepositoryIdentityExact=$idExact
        IdentityExact=($idExact -and $labelsExact -and $registrationId -match '^[1-9][0-9]*$' -and $registrationId -ceq [string]$script:expectedRunnerId)
        RunnerIdentityExact=($idExact -and $labelsExact -and $registrationId -match '^[1-9][0-9]*$')
        RunnerId=$registrationId
        RunnerOnlineIdle=($matching.Count -eq 1 -and [string]$matching[0].status -eq 'online' -and -not [bool]$matching[0].busy)
        ServiceExact=$serviceExact; ServiceState=[string]$service.State
        WorkflowExact=(Test-TrustedWorkflow); DispatchState=(Get-DispatchState)
        Quiescent=($quiet.Result -eq 'PASS' -and $quiet.Reason -eq 'NO_CURRENT_EXECUTION'); RuntimeClassification=$runtime.Classification; MachinePath=$runtime.MachinePath
        PackageVerified=$packageVerified; UnknownState=$false
    }
}
function Assert-IntentDirectory {
    if(-not(Test-Path -LiteralPath $intentDirectory)){return}
    if(-not(Test-Path -LiteralPath $intentDirectory -PathType Container) -or -not(Test-Phase12BNoReparse $intentDirectory) -or (-not $TestMode -and -not(Test-Phase12BAclPolicy -Acl (Get-Acl -LiteralPath $intentDirectory)))){throw 'Runtime intent directory or ACL is unsafe.'}
    $unexpected=@(Get-ChildItem -LiteralPath $intentDirectory -Force -ErrorAction Stop|Where-Object{$_.Name -cnotin @('powershell7-intent.json','packages')})
    if($unexpected.Count -ne 0){throw 'Runtime intent directory contains unknown or interrupted content.'}
    $packageDirectory=Join-Path $intentDirectory 'packages'
    if(Test-Path -LiteralPath $packageDirectory){
        if(-not(Test-Path -LiteralPath $packageDirectory -PathType Container) -or -not(Test-Phase12BNoReparse $packageDirectory) -or (-not $TestMode -and -not(Test-Phase12BAclPolicy -Acl (Get-Acl -LiteralPath $packageDirectory)))){throw 'Runtime package cache or ACL is unsafe.'}
        if(@(Get-ChildItem -LiteralPath $packageDirectory -Force -ErrorAction Stop|Where-Object{$_.Name -cne $policy.Asset}).Count -ne 0){throw 'Runtime package cache contains unknown content.'}
    }
}
function Read-Intent {
    Assert-IntentDirectory
    if (-not (Test-Path -LiteralPath $intentPath)) { return $null }
    if (-not (Test-Path -LiteralPath $intentPath -PathType Leaf) -or -not (Test-Phase12BNoReparse $intentPath)) { throw 'Runtime intent path is unsafe.' }
    try { $intent = Get-Content -LiteralPath $intentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Runtime intent is malformed.' }
    if ([string]$intent.schema -ne '1' -or [string]$intent.operation -cne 'SYSTEM_POWERSHELL7' -or [string]$intent.host_id -cne [string]$h.host_id -or
        [string]$intent.repository_id -cne [string]$caller.RepositoryId -or [string]$intent.repository_full_name -cne [string]$caller.Repository -or
        [string]$intent.service_name -ine [string]$identity.ServiceName -or [string]$intent.version -cne $policy.Version -or
        [string]$intent.sha256 -cne $policy.Sha256 -or [string]$intent.initial_dispatch_state -notin @('active','disabled_manually') -or
        [string]$intent.runner_id -notmatch '^[1-9][0-9]*$') { throw 'Runtime intent authority conflicts with current desired state.' }
    $intent
}
function Save-Intent([string]$Stage) {
    $script:intent.stage = $Stage
    Assert-IntentDirectory
    $temp = Join-Path $intentDirectory ('.powershell7-intent.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($script:intent | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $intentPath -Force -ErrorAction Stop
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

$script:intent = Read-Intent
$initial = Get-ActualState
if ($null -eq $script:intent) {
    $decision = Get-Phase12BSystemRuntimeDecision -State $initial
    @('SYSTEM_RUNTIME_PLAN',"HOST_STATE=$hostState","CALLER=$($caller.Repository)","SERVICE=$($identity.ServiceName)","POWERSHELL7=$($initial.RuntimeClassification)","DISPATCH_INITIAL=$($initial.DispatchState)","DECISION=$decision",("RESULT={0}" -f $(if($Approve){'APPLY'}else{'PLAN'}))) -join "`n"
    if ($decision -eq 'CONFLICT') { throw 'System runtime dependency plan is conflicted.' }
    if (-not $Approve) { exit 0 }
    if (-not $initial.Quiescent) { throw 'System runtime apply requires quiescence before dispatch fence.' }
    if (-not (Test-Path -LiteralPath $intentDirectory)) { New-Item -ItemType Directory -Path $intentDirectory -ErrorAction Stop | Out-Null; if(-not $TestMode){Invoke-Phase12BAction -Name ApplyAcl -Argument $intentDirectory} }
    Assert-IntentDirectory
    $script:intent = [pscustomobject]@{schema=1;operation='SYSTEM_POWERSHELL7';host_id=$h.host_id;repository_id=$caller.RepositoryId;repository_full_name=$caller.Repository;service_name=$identity.ServiceName;runner_id=$initial.RunnerId;initial_dispatch_state=$initial.DispatchState;version=$policy.Version;sha256=$policy.Sha256;stage='PLANNED';state_entered_at=[DateTimeOffset]::UtcNow.ToString('o')}
    $script:expectedRunnerId = [string]$initial.RunnerId
    Save-Intent 'PLANNED'
} else {
    $script:expectedRunnerId = [string]$script:intent.runner_id
    if (-not $Approve) { @('SYSTEM_RUNTIME_PLAN',"STAGE=$($script:intent.stage)",'RESULT=RESUME_REQUIRES_APPROVAL') -join "`n"; exit 0 }
}

$read = { Get-ActualState }
$save = { param($stage) Save-Intent $stage }
$mutate = {
    param($action)
    if($TestMode){
        $fixture=Read-FixtureState
        $calls=@(if($fixture.PSObject.Properties['mutation_calls']){$fixture.mutation_calls});$calls+=$action
        $fixture|Add-Member -NotePropertyName mutation_calls -NotePropertyValue $calls -Force
        if([string]$fixture.fail_action -ceq $action){Write-FixtureState $fixture;throw "Injected runtime provider failure: $action"}
        switch($action){
            'FenceDispatch'{$fixture.dispatch_state='disabled_manually'}
            'WaitForQuiescence'{$fixture.quiescent=$true;$fixture.quiescence_reason='NO_CURRENT_EXECUTION'}
            'VerifyPackage'{$fixture.package_verified=$true}
            'InstallRuntime'{$fixture.runtime_observation=[pscustomobject]@{DirectoryPresent=$true;DirectoryIsContainer=$true;DirectoryNonReparse=$true;LeafPresent=$true;LeafNonReparse=$true;SignatureValid=$true;Version=$policy.Version;X64=$true;MachinePath='EXACT'}}
            'StopService'{$fixture.service_state='Stopped';$fixture.runner_online_idle=$false}
            'StartService'{$fixture.service_state='Running';$fixture.runner_online_idle=$true}
            'WaitForRunnerOnline'{$fixture.runner_online_idle=$true}
            'RestoreDispatch'{$fixture.dispatch_state='active'}
            default{throw 'Unsupported runtime fixture provider action.'}
        }
        Write-FixtureState $fixture
        return
    }
    switch ($action) {
        'FenceDispatch' { & gh api --method PUT ($workflowApi + '/disable') | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Dispatch fence mutation failed.' } }
        'WaitForQuiescence' { $q = Wait-Phase12BCallerQuiescence -ExecutionRoot $h.execution_root -RepositoryId $caller.RepositoryId -RepositoryFullName $caller.Repository -TimeoutSeconds ([int]$h.quiescence_timeout_seconds); if ($q.Result -ne 'PASS' -or $q.Reason -ne 'NO_CURRENT_EXECUTION') { throw 'System-wide quiescence was not proven.' } }
        'VerifyPackage' { Get-Phase12BVerifiedSystemRuntimePackage -RuntimeRoot $intentDirectory | Out-Null }
        'InstallRuntime' { Install-Phase12BSystemRuntime -RuntimeRoot $intentDirectory | Out-Null }
        'StopService' { Stop-Service -Name $identity.ServiceName -ErrorAction Stop; (Get-Service -Name $identity.ServiceName -ErrorAction Stop).WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2)) }
        'StartService' { Start-Service -Name $identity.ServiceName -ErrorAction Stop; (Get-Service -Name $identity.ServiceName -ErrorAction Stop).WaitForStatus('Running', [TimeSpan]::FromMinutes(2)) }
        'WaitForRunnerOnline' {
            $deadline=[DateTime]::UtcNow.AddMinutes(2)
            do {
                $snapshot=Get-ActualState
                if(-not $snapshot.IdentityExact -or -not $snapshot.ServiceExact -or $snapshot.ServiceState -ne 'Running'){throw 'Runner identity or Service changed while waiting for online read-back.'}
                if($snapshot.RunnerOnlineIdle){break}
                Start-Sleep -Seconds 3
            } while([DateTime]::UtcNow -lt $deadline)
            if(-not $snapshot.RunnerOnlineIdle){throw 'Exact runner did not become online and idle.'}
        }
        'RestoreDispatch' { & gh api --method PUT ($workflowApi + '/enable') | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Dispatch restore mutation failed.' } }
        default { throw 'Unsupported runtime mutation.' }
    }
}
Invoke-Phase12BSystemRuntimeLifecycle -InitialStage ([string]$script:intent.stage) -InitialDispatchState ([string]$script:intent.initial_dispatch_state) -Read $read -Mutate $mutate -Save $save | Out-Null
'SYSTEM_RUNTIME_APPLY=PASS'
