[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PrivateConfig,
    [switch]$Approve,
    [switch]$TestMode,
    [string]$FixtureRoot,
    [string]$AdapterLog,
    [string]$ExternalReadbackFile,
    [string]$ServiceReadbackFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
Test-Phase12BTestAdapter -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog -ExternalReadbackFile $ExternalReadbackFile -ServiceReadbackFile $ServiceReadbackFile
$cfg=Read-Phase12BConfig $PrivateConfig;$h=$cfg.Host
$state=Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root
$package=$h.runner_package_path
$plan=@('HOST_BOOTSTRAP_PLAN',"HOST_ID=$($h.host_id)","HOST_STATE=$state","CREATE_RUNTIME_ROOT=$($state -eq 'NEW')","CREATE_PROFILE_ROOT=$($state -eq 'NEW')","CREATE_EXECUTION_AREA=$($state -eq 'NEW')","CHANGE_ACL=$($state -eq 'NEW')","CREATE_RUNNER_ROOT=$($state -eq 'NEW')",("CALLER_RUNNERS={0}" -f $cfg.Callers.Count),'RUNNER_PACKAGE_BEFORE_CONFIG=true','INSTALL_WINDOWS_SERVICES=true','SERVICE_IDENTITY=NT AUTHORITY\NETWORK SERVICE',"PRIVATE_CONFIG=$PrivateConfig",'APPROVAL_REQUIRED=true',("RESULT={0}" -f $(if($Approve){'APPLY'}else{'PLAN'})))
$plan -join "`n"
if(-not $Approve){exit 0}
if($state -ne 'NEW'){throw "Approved bootstrap requires wholly NEW host, got $state."}
if(-not $AdapterLog){if([string]::IsNullOrWhiteSpace($package) -or -not(Test-Path -LiteralPath $package -PathType Leaf) -or -not(Test-Phase12BNoReparse $package)){throw 'Approved bootstrap requires a non-reparse runner package path grounded by host desired state.'}}
foreach($path in @($h.runtime_root,$h.profile_root,$h.runner_root)){Invoke-Phase12BAction -Name EnsureDirectory -Argument $path -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog}
$runtimeJson=(@{schema=1;host_id=$h.host_id;service_identity='NT AUTHORITY\NETWORK SERVICE';service_sid='S-1-5-20';execution_root=$h.execution_root;runtime_root=$h.runtime_root}|ConvertTo-Json -Compress)
Invoke-Phase12BAction -Name WriteRuntime -Argument (Join-Path $h.runtime_root 'runtime.json') -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog -RuntimeJson $runtimeJson
Invoke-Phase12BAction -Name EnsureExecutionArea -Argument $h.execution_root -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog
foreach($path in @($h.runtime_root,$h.profile_root,$h.execution_root,$h.runner_root)){Invoke-Phase12BAction -Name ApplyAcl -Argument $path -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog}
foreach($caller in $cfg.Callers){
    if($TestMode -and -not(Test-Path -LiteralPath (Join-Path $FixtureRoot 'caller-runner-fixture.json'))){Write-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot -Fixture ([ordered]@{schema=1;repository_id=$caller.RepositoryId;repository_full_name=$caller.Repository;local_present=$false;runners=@();services=@();workflow_state='ABSENT';current_run_repository_id='';mutex_state='FREE'})}
    $result=Invoke-Phase12BCallerRunner -Action Onboard -HostConfig $cfg.HostFile -RepositoryFullName $caller.Repository -RepositoryId $caller.RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot
    if($result.LifecycleAfter -ne 'ACTIVE'){throw 'Canonical caller lifecycle did not reach ACTIVE during bootstrap.'}
}
if($AdapterLog){
    $actions=Get-Content -LiteralPath $AdapterLog -Raw -ErrorAction Stop
    foreach($name in 'EnsureDirectory','WriteRuntime','EnsureExecutionArea','ApplyAcl'){if($actions -notmatch "ACTION=$name"){throw "Bootstrap test adapter did not observe $name."}}
} else {
    if((Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root) -ne 'EXISTING'){throw 'Bootstrap local host verification failed.'}
}
foreach($caller in $cfg.Callers){
    $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $h.runner_root -RepositoryId $caller.RepositoryId;$external=Get-Phase12BExternalCallerState -Config $cfg -Caller $caller -TestMode:$TestMode -FixtureRoot $FixtureRoot -ExternalReadbackFile $ExternalReadbackFile;$check=Test-Phase12BExternalCallerState -Config $cfg -Caller $caller -External $external -RunnerName $identity.RunnerName;if(-not $check.All){throw "Bootstrap external read-back contradicts desired caller state: $($check|ConvertTo-Json -Compress)"}
    $verified=Invoke-Phase12BCallerRunner -Action Verify -HostConfig $cfg.HostFile -RepositoryFullName $caller.Repository -RepositoryId $caller.RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot;if($verified.LifecycleAfter -ne 'ACTIVE'){throw 'Bootstrap did not leave canonical ACTIVE metadata.'}
}
'BOOTSTRAP_APPLY=PASS'
