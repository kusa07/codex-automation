[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('InstallPackage','Register','InstallService','StartService','StopService','Unregister','RemoveService','MigrateRunner','Verify')][string]$Action,
    [string]$Repository,[string]$RepositoryId,[Parameter(Mandatory=$true)][string]$RunnerRoot,[string]$ServiceName,
    [string]$ServiceIdentity='NT AUTHORITY\NETWORK SERVICE',[string]$RunnerPackagePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($Repository -and $Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'Invalid repository identity.'}
if($RepositoryId -and $RepositoryId -notmatch '^[1-9][0-9]*$'){throw 'Invalid repository ID.'}
if(-not(Test-Path -LiteralPath $RunnerRoot -PathType Container)){throw 'Runner root is missing.'}
$root=Get-Item -LiteralPath $RunnerRoot -Force;if(($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runner root must not be a reparse point.'}
if($ServiceIdentity -notin @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')){throw 'Runner service identity is not approved.'}
$config=Join-Path $RunnerRoot 'config.cmd';$run=Join-Path $RunnerRoot 'run.cmd';$serviceFile=Join-Path $RunnerRoot '.service'
function Get-OfficialServiceName {
    if(-not(Test-Path -LiteralPath $serviceFile -PathType Leaf)){throw 'Official runner .service metadata is missing.'}
    $name=(Get-Content -LiteralPath $serviceFile -Raw -ErrorAction Stop).Trim()
    if($name -notmatch '^actions\.runner\.[A-Za-z0-9_.-]+$'){throw 'Official runner .service metadata is invalid.'}
    if($ServiceName -and $ServiceName -ine $name){throw 'Requested service name contradicts official runner metadata.'}
    $name
}
function Get-ExactService { $name=Get-OfficialServiceName;$s=Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop;if($s -and $s.StartName -notin @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')){throw 'Existing runner service identity contradicts desired state.'};return $s }
function Assert-ServicePath($s){$expected=[regex]::Escape([IO.Path]::GetFullPath((Join-Path $RunnerRoot 'bin\RunnerService.exe')));if(-not $s -or -not $s.PathName -or $s.PathName -notmatch ('(?i)^\s*"?{0}"?\s*$' -f $expected)){throw 'Runner service is not hosted by the official RunnerService.exe.'}}
function Get-EphemeralRunnerToken([ValidateSet('registration-token','remove-token')][string]$Kind){
    if([string]::IsNullOrWhiteSpace($Repository)){throw 'Repository is required for runner token acquisition.'}
    $gh=Get-Command gh -ErrorAction Stop
    $token=(& $gh.Source api --method POST "repos/$Repository/actions/runners/$Kind" --jq '.token' 2>$null|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token) -or $token.Length -gt 4096){throw "GitHub $Kind acquisition failed."}
    $token
}
switch($Action){
 'InstallPackage' {
    $package=$RunnerPackagePath
    if([string]::IsNullOrWhiteSpace($package) -or -not(Test-Path -LiteralPath $package -PathType Leaf)){throw 'Runner package availability is not grounded by host desired state.'}
    $p=Get-Item -LiteralPath $package -Force;if(($p.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runner package must not be a reparse point.'}
    if(@(Get-ChildItem -LiteralPath $RunnerRoot -Force).Count -ne 0){throw 'Runner package target must be an empty, newly prepared runner root.'}
    Expand-Archive -LiteralPath $package -DestinationPath $RunnerRoot -ErrorAction Stop
    if(-not(Test-Path -LiteralPath $config -PathType Leaf) -or -not(Test-Path -LiteralPath $run -PathType Leaf)){throw 'Installed runner package lacks config.cmd or run.cmd.'}
 }
 'Register' {
    if(-not(Test-Path -LiteralPath $config -PathType Leaf)){throw 'Runner config.cmd is missing after package installation.'}
    $token=Get-EphemeralRunnerToken registration-token
    try { & $config --unattended --url ("https://github.com/{0}" -f $Repository) --token $token --name ("codex-repo-{0}" -f $RepositoryId) --labels 'self-hosted,Windows,X64,codex-automation' --runasservice --windowslogonaccount 'NT AUTHORITY\NETWORK SERVICE'|Out-Null;if($LASTEXITCODE -ne 0){throw 'Official runner service configuration failed.'} }
    finally { $token=$null }
    $s=Get-ExactService;Assert-ServicePath $s
  }
  'InstallService' {
    $s=Get-ExactService;Assert-ServicePath $s
  }
  'StartService' { $name=Get-OfficialServiceName;$s=Get-ExactService;Assert-ServicePath $s;if($s.State -ne 'Running'){Start-Service -Name $name -ErrorAction Stop};$s=Get-ExactService;if($s.State -ne 'Running'){throw 'Runner service did not reach Running state.'} }
  'StopService' { $name=Get-OfficialServiceName;$s=Get-ExactService;Assert-ServicePath $s;if($s.State -ne 'Stopped'){Stop-Service -Name $name -ErrorAction Stop};$s=Get-ExactService;if($s.State -ne 'Stopped'){throw 'Runner service did not reach Stopped state.'} }
  'Unregister' { if(-not(Test-Path -LiteralPath $config -PathType Leaf)){throw 'Runner config.cmd is missing.'};$token=Get-EphemeralRunnerToken remove-token;try{& $config remove --token $token|Out-Null;if($LASTEXITCODE -ne 0){throw 'Runner unregistration failed.'}}finally{$token=$null} }
  'RemoveService' { if(Test-Path -LiteralPath $serviceFile){throw 'Official config remove did not remove .service metadata.'};if($ServiceName){$s=Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop;if($s){throw 'Official config remove did not remove the Windows Service.'}} }
  'MigrateRunner' { if(-not(Test-Path -LiteralPath $config -PathType Leaf)){throw 'Runner config.cmd is missing.'};$s=Get-ExactService;if(-not $s){throw 'Runner service is missing; migration requires canonical onboarding.'};Assert-ServicePath $s }
 'Verify' { if(-not(Test-Path -LiteralPath (Join-Path $RunnerRoot '.runner') -PathType Leaf)){throw 'Runner registration marker is missing.'};$s=Get-ExactService;Assert-ServicePath $s;if($s.State -notin @('Running','Stopped')){throw 'Runner service state is invalid.'} }
}
Write-Output ("RUNNER_ADAPTER={0};RESULT=PASS" -f $Action)
