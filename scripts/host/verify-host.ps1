[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PrivateConfig)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
$state = Get-Phase12BHostState -RuntimeRoot 'C:\ProgramData\CodexAutomation' -ExecutionRoot 'C:\codex-self-hosted' -HostId 'main-windows-runner'
$result = 'STOP'
if ($state -eq 'EXISTING') { $result = 'PASS' }
@('HOST_VERIFY', "RESULT=$result", 'HOST_ID=main-windows-runner', 'SERVICE_IDENTITY=NETWORK_SERVICE', "HOST_RUNTIME=$state", "PRIVATE_CONFIG=$PrivateConfig", 'NEXT_ACTION=NONE') -join "`n"
