[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PrivateConfig,[switch]$Approve,[switch]$TestMode,[string]$FixtureRoot,[string]$AdapterLog,[string]$ExternalReadbackFile,[string]$ServiceReadbackFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
Test-Phase12BTestAdapter -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog -ExternalReadbackFile $ExternalReadbackFile -ServiceReadbackFile $ServiceReadbackFile
$cfg=Read-Phase12BConfig $PrivateConfig;$h=$cfg.Host;$state=Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root;$quiet=Test-Phase12BQuiescent $h.execution_root
$serviceRecords=if($ServiceReadbackFile){@(Get-Content -LiteralPath $ServiceReadbackFile -Raw|ConvertFrom-Json)}else{$null}
$services=@();foreach($caller in $cfg.Callers){$root=(Get-Phase12BCallerRunnerIdentity -RunnerRoot $h.runner_root -RepositoryId $caller.RepositoryId).RunnerDirectory;if($ServiceReadbackFile){$services += Get-Phase12BServiceForRunner -RunnerRoot $root -ServiceRecords $serviceRecords}else{$services += Get-Phase12BServiceForRunner $root}}
$serviceGrounding=if(@($services|Where-Object{$_.Classification -ne 'EXISTING'}).Count -eq 0){'PASS'}else{'FAIL'}
@('HOST_MIGRATION_PLAN',"CURRENT_STATE=$state","QUIESCENT=$quiet","SERVICE_GROUNDING=$serviceGrounding",'TARGET_SERVICE_IDENTITY=NT AUTHORITY\NETWORK SERVICE','APPROVAL_REQUIRED=true',("RESULT={0}" -f $(if($Approve){'APPLY'}else{'PLAN'}))) -join "`n"
if(-not $Approve){exit 0}
if($state -ne 'EXISTING' -or -not $quiet -or $serviceGrounding -ne 'PASS'){throw 'Migration requires an existing, consistent, quiescent host with exactly mapped services.'}
foreach($caller in $cfg.Callers){
  $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $h.runner_root -RepositoryId $caller.RepositoryId;$root=$identity.RunnerDirectory;$actual=$services[[array]::IndexOf($cfg.Callers,$caller)]
  if($actual.Classification -ne 'EXISTING' -or [string]::IsNullOrWhiteSpace($actual.ServiceName) -or -not(Test-Phase12BServicePath $actual.PathName $root)){throw 'Runner service mapping is contradictory.'}
  $external=Get-Phase12BExternalCallerState -Config $cfg -Caller $caller -TestMode:$TestMode -FixtureRoot $FixtureRoot -ExternalReadbackFile $ExternalReadbackFile;$pre=Test-Phase12BExternalCallerState -Config $cfg -Caller $caller -External $external -RunnerName $identity.RunnerName;if(-not $pre.All){throw 'Migration pre-state external read-back contradicts desired caller state.'}
  if($TestMode){
    New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $root '.service') -Value $actual.ServiceName -NoNewline;Set-Content -LiteralPath (Join-Path $root 'bin\RunnerService.exe') -Value fixture -NoNewline
    Write-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot -Fixture ([ordered]@{schema=1;repository_id=$caller.RepositoryId;repository_full_name=$caller.Repository;local_present=$true;runners=@($external.Runners);services=@($serviceRecords);workflow_state='PRESENT';current_run_repository_id='';mutex_state='FREE'})
  }
  $canonical=Invoke-Phase12BCallerRunner -Action Onboard -HostConfig $cfg.HostFile -RepositoryFullName $caller.Repository -RepositoryId $caller.RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot
  if($canonical.LifecycleAfter -ne 'ACTIVE'){throw 'Canonical migration did not produce ACTIVE lifecycle metadata.'}
  $post=Get-Phase12BExternalCallerState -Config $cfg -Caller $caller -TestMode:$TestMode -FixtureRoot $FixtureRoot -ExternalReadbackFile $ExternalReadbackFile;$check=Test-Phase12BExternalCallerState -Config $cfg -Caller $caller -External $post -RunnerName $identity.RunnerName;if(-not $check.All){throw 'Migration post-state external read-back contradicts desired caller state.'}
}
if((Get-Phase12BHostState -RuntimeRoot $h.runtime_root -ExecutionRoot $h.execution_root -HostId $h.host_id -ProfileRoot $h.profile_root -RunnerRoot $h.runner_root) -ne 'EXISTING'){throw 'Migration local verification failed.'}
'MIGRATE_APPLY=PASS'
