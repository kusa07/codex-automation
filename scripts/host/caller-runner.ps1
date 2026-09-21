[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Inspect','Onboard','Offboard','Verify')][string]$Action,
    [Parameter(Mandatory=$true)][string]$HostConfig,
    [Parameter(Mandatory=$true)][string]$RepositoryFullName,
    [Parameter(Mandatory=$true)][string]$RepositoryId,
    [switch]$BeginRetirement,
    [switch]$FinalizeRetirement,
    [switch]$TestMode,
    [string]$FixtureRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# This file is intentionally a thin, fixed CLI. Provider selection,
# classification, lifecycle transitions, and validation belong to the module.
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
$result=Invoke-Phase12BCallerRunner @PSBoundParameters

@(
    "ACTION=$($result.Action)"
    "RESULT=$($result.Result)"
    "REPOSITORY_ID=$($result.RepositoryId)"
    "HOST_STATE=$($result.HostState)"
    "CALLER_RUNNER_SNAPSHOT_STATE=$($result.Snapshot)"
    "CALLER_RUNNER_LIFECYCLE_STATE_BEFORE=$($result.LifecycleBefore)"
    "CALLER_RUNNER_LIFECYCLE_STATE_AFTER=$($result.LifecycleAfter)"
    "RECOVERY_DECISION=$($result.Recovery)"
    "RECONSTRUCT_RUNTIME_METADATA=$([string]$result.ReconstructRuntimeMetadata).ToLowerInvariant()"
    "RUNNER_DIRECTORY=$($result.Identity.RunnerDirectory)"
    "RUNNER_NAME=$($result.Identity.RunnerName)"
    "SERVICE_NAME=$($result.Identity.ServiceName)"
    "SERVICE_STATE=$($result.ServiceState)"
    "STATE_ENTERED_AT=$($result.StateEnteredAt)"
    "MUTATIONS_PERFORMED=$($result.Mutations)"
    "POSTCONDITION=$($result.Postcondition)"
    "NEXT_ACTION=$($result.NextAction)"
) -join "`n"
