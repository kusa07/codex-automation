$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
$root = Join-Path $env:TEMP ('phase12b-host-test-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $root 'runtime'
$execution = Join-Path $root 'execution'
$areaHelper = Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1'
try {
    if ((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId 'host') -ne 'NEW') { throw 'NEW classification failed' }
    New-Item -ItemType Directory -Path $runtime | Out-Null
    if ((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId 'host') -ne 'INCONSISTENT') { throw 'runtime-only classification failed' }
    Remove-Item -LiteralPath $runtime -Recurse -Force
    & $areaHelper -Action ensure -Root $execution | Out-Null
    if ((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId 'host') -ne 'INCONSISTENT') { throw 'execution-only classification failed' }
    New-Item -ItemType Directory -Path $runtime | Out-Null
    @{ schema=1; host_id='host'; service_identity='NT AUTHORITY\NETWORK SERVICE'; service_sid='S-1-5-20'; execution_root=$execution; runtime_root=$runtime } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'runtime.json') -NoNewline
    if ((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId 'host') -ne 'EXISTING') { throw 'EXISTING classification failed' }
    Set-Content -LiteralPath (Join-Path $execution '.codex-automation-managed') '{malformed' -NoNewline
    if ((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId 'host') -ne 'INCONSISTENT') { throw 'bad marker classification failed' }
    if ((Get-Phase12BRunnerState -LocalPresent:$false -ServicePresent:$false -GitHubPresent:$false -ExpectedRepositoryId '1' -ActualRepositoryId '' -ActualServiceIdentity '' -ExpectedLabels @() -ActualLabels @()) -ne 'NEW') { throw 'runner NEW failed' }
    if ((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$true -GitHubPresent:$true -ExpectedRepositoryId '1' -ActualRepositoryId '1' -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @('X64') -ActualLabels @('X64')) -ne 'EXISTING') { throw 'runner EXISTING failed' }
    if ((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$false -GitHubPresent:$true -ExpectedRepositoryId '1' -ActualRepositoryId '1' -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @('X64') -ActualLabels @('X64')) -ne 'INCONSISTENT') { throw 'runner inconsistent failed' }
    if ((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$true -GitHubPresent:$true -ExpectedRepositoryId '1' -ActualRepositoryId '1' -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @() -ActualLabels @()) -ne 'INCONSISTENT') { throw 'runner empty-label policy failed' }
    if (-not (Test-Phase12BAclPolicy -Principals @('NT AUTHORITY\NETWORK SERVICE','BUILTIN\Administrators','NT AUTHORITY\SYSTEM'))) { throw 'ACL policy acceptance failed' }
    if (Test-Phase12BAclPolicy -Principals @('NT AUTHORITY\NETWORK SERVICE','BUILTIN\Administrators','NT AUTHORITY\SYSTEM','Everyone')) { throw 'broad ACL policy passed' }
    if (Test-Phase12BAclPolicy -Principals @('NT AUTHORITY\NETWORK SERVICE','BUILTIN\Administrators','NT AUTHORITY\SYSTEM','S-1-5-21-111-222-333-1001')) { throw 'personal SID ACL policy passed' }
    'phase12b host state tests passed'
} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
