[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PrivateConfig,
    [switch]$Approve
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force

if ($Approve) { throw 'Batch A provides a bootstrap plan only; host mutation requires the later approved Batch C migration.' }
$runtimeRoot = 'C:\ProgramData\CodexAutomation'
$executionRoot = 'C:\codex-self-hosted'
$hostId = 'main-windows-runner'
$state = Get-Phase12BHostState -RuntimeRoot $runtimeRoot -ExecutionRoot $executionRoot -HostId $hostId
@(
    'HOST_BOOTSTRAP_PLAN', "HOST_ID=$hostId", "HOST_STATE=$state",
    "CREATE_RUNTIME_ROOT=$($state -eq 'NEW')", "CREATE_PROFILE_ROOT=$($state -eq 'NEW')",
    "CREATE_EXECUTION_AREA=$($state -eq 'NEW')", "CHANGE_ACL=$($state -eq 'NEW')",
    "CREATE_RUNNER_ROOT=$($state -eq 'NEW')", 'CREATE_RUNNERS=false',
    'INSTALL_WINDOWS_SERVICES=false', 'SERVICE_IDENTITY=NT AUTHORITY\NETWORK SERVICE',
    "PRIVATE_CONFIG=$PrivateConfig", 'UNEXPECTED_STATE=false', 'RESULT=STOP'
) -join "`n"
