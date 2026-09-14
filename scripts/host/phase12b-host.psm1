Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Phase12BServiceIdentity = 'NT AUTHORITY\NETWORK SERVICE'
$script:Phase12BServiceSid = 'S-1-5-20'
$script:Phase12BBroadAclPrincipals = @('Everyone', 'BUILTIN\Users', 'Users', 'Authenticated Users')

function New-Phase12BResult([string]$Result, [hashtable]$Values = @{}) {
    [ordered]@{ RESULT = $Result } + $Values
}

function Test-Phase12BNoReparse([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($item -is [System.IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
    return $true
}

function Read-Phase12BRuntime([string]$RuntimeRoot) {
    $runtime = Join-Path $RuntimeRoot 'runtime.json'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf) -or -not (Test-Phase12BNoReparse $runtime)) { return $null }
    try { return (Get-Content -LiteralPath $runtime -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-Phase12BHostState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ExecutionRoot,
        [Parameter(Mandatory = $true)][string]$HostId
    )
    $runtimeExists = Test-Path -LiteralPath $RuntimeRoot -PathType Container
    $executionExists = Test-Path -LiteralPath $ExecutionRoot -PathType Container
    if (-not $runtimeExists -and -not $executionExists) { return 'NEW' }
    if (-not $runtimeExists -or -not $executionExists) { return 'INCONSISTENT' }
    if (-not (Test-Phase12BNoReparse $RuntimeRoot) -or -not (Test-Phase12BNoReparse $ExecutionRoot)) { return 'INCONSISTENT' }
    $executionHelper = Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1'
    try { & $executionHelper -Action preflight -Root $ExecutionRoot | Out-Null } catch { return 'INCONSISTENT' }
    $runtime = Read-Phase12BRuntime $RuntimeRoot
    if ($null -eq $runtime) { return 'INCONSISTENT' }
    $expected = @{
        schema = 1; host_id = $HostId; service_identity = $script:Phase12BServiceIdentity;
        service_sid = $script:Phase12BServiceSid; execution_root = $ExecutionRoot; runtime_root = $RuntimeRoot
    }
    foreach ($key in $expected.Keys) {
        if ([string]$runtime.$key -cne [string]$expected[$key]) { return 'INCONSISTENT' }
    }
    return 'EXISTING'
}

function Get-Phase12BRunnerState {
    [CmdletBinding()]
    param(
        [bool]$LocalPresent,
        [bool]$ServicePresent,
        [bool]$GitHubPresent,
        [string]$ExpectedRepositoryId,
        [string]$ActualRepositoryId,
        [string]$ActualServiceIdentity,
        [string[]]$ExpectedLabels = @(),
        [string[]]$ActualLabels = @()
    )
    if (-not $LocalPresent -and -not $ServicePresent -and -not $GitHubPresent) { return 'NEW' }
    if (-not ($LocalPresent -and $ServicePresent -and $GitHubPresent)) { return 'INCONSISTENT' }
    if ([string]::IsNullOrWhiteSpace($ExpectedRepositoryId) -or $ExpectedRepositoryId -cne $ActualRepositoryId -or $ExpectedLabels.Count -eq 0) { return 'INCONSISTENT' }
    if ($ActualServiceIdentity -cne $script:Phase12BServiceIdentity) { return 'INCONSISTENT' }
    if (@(Compare-Object ($ExpectedLabels | Sort-Object) ($ActualLabels | Sort-Object)).Count -ne 0) { return 'INCONSISTENT' }
    return 'EXISTING'
}

function Test-Phase12BAclPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Principals)
    $expected = @($script:Phase12BServiceIdentity, 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM' | Sort-Object)
    $actual = @($Principals | Sort-Object -Unique)
    return @(Compare-Object $expected $actual).Count -eq 0
}

Export-ModuleMember -Function New-Phase12BResult, Test-Phase12BNoReparse, Read-Phase12BRuntime, Get-Phase12BHostState, Get-Phase12BRunnerState, Test-Phase12BAclPolicy
