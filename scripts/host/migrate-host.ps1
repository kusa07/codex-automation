[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PrivateConfig, [switch]$Approve)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Approve) { throw 'Batch A intentionally does not execute host migrations.' }
@('HOST_MIGRATION_PLAN', 'RESULT=STOP', "PRIVATE_CONFIG=$PrivateConfig", 'QUIESCENCE_REQUIRED=true', 'NO_ACTIVE_WORKFLOW_RUN=true', 'NO_QUEUED_WORKFLOW_RUN=true', 'NO_ACTIVE_LOCAL_EXECUTION=true', 'NO_HELD_GLOBAL_MUTEX=true', 'NO_RESIDUAL_EXECUTION_STATE=true', 'TARGET_SERVICE_IDENTITY=NT AUTHORITY\NETWORK SERVICE') -join "`n"
