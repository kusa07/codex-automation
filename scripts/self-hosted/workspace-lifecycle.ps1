[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('prepare', 'cleanup', 'recover', 'preflight')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$RepositoryUrl,
    [string]$LocalSourcePath,
    [Parameter(Mandatory = $true)][string]$ExpectedRepository,
    [Parameter(Mandatory = $true)][string]$BaseSha,
    [Parameter(Mandatory = $true)][string]$WorkspaceName,
    [Parameter(Mandatory = $true)][string]$ExecutionId,
    [string]$ExpectedFinalSha,
    [switch]$ActiveRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ManagedAreaHelper = Join-Path $PSScriptRoot 'managed-execution-area.ps1'
$WorkspaceSchema = 1

function Fail([string]$Message) { Write-Output 'FAIL_CLOSED'; throw "workspace lifecycle failed closed: $Message" }
function FullPath([string]$Path) { try { return [IO.Path]::GetFullPath($Path) } catch { Fail 'invalid root' } }
function Assert-Token([string]$Value, [string]$Name, [string]$Pattern) { if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch $Pattern) { Fail "$Name is invalid" } }
function Assert-Inputs {
    Assert-Token $BaseSha 'base SHA' '^[0-9a-fA-F]{40}$'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFinalSha)) { Assert-Token $ExpectedFinalSha 'expected final SHA' '^[0-9a-fA-F]{40}$' }
    Assert-Token $ExecutionId 'execution ID' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    Assert-Token $WorkspaceName 'workspace name' '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    Assert-Token $ExpectedRepository 'repository identity' '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
    if ($Action -eq 'prepare' -and [string]::IsNullOrWhiteSpace($RepositoryUrl) -eq ([string]::IsNullOrWhiteSpace($LocalSourcePath))) { Fail 'exactly one repository source is required' }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryUrl) -and ($RepositoryUrl -notmatch '^(https://github\.com/|git@github\.com:)' -or $RepositoryUrl -match '[\r\n]')) { Fail 'repository URL is not an allowed GitHub URL' }
    if (-not [string]::IsNullOrWhiteSpace($LocalSourcePath) -and $LocalSourcePath -match '[\r\n]') { Fail 'local source path is invalid' }
}
function Invoke-ManagedPreflight([string]$FullRoot) { & $ManagedAreaHelper -Action preflight -Root $FullRoot | Out-Null }
function Assert-ManagedWorkspaceBoundary([string]$FullRoot) {
    if (-not (Test-Path -LiteralPath $FullRoot -PathType Container)) { Fail 'managed root is missing' }
    $rootItem = Get-Item -LiteralPath $FullRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'managed root is a reparse point' }
    $expected = @('.codex-automation-managed','state','workspaces','codex-home','temp','logs')
    $actual = @(Get-ChildItem -LiteralPath $FullRoot -Force | ForEach-Object { $_.Name })
    foreach ($entry in $actual) { if ($expected -notcontains $entry) { Fail 'managed root contains an unexpected entry' } }
    foreach ($entry in $expected) {
        $path = Join-Path $FullRoot $entry
        if (-not (Test-Path -LiteralPath $path)) { Fail 'managed root is missing a required entry' }
        if ($entry -ne '.codex-automation-managed' -and -not (Test-Path -LiteralPath $path -PathType Container)) { Fail 'managed root entry has an unexpected type' }
    }
    Assert-NoReparsePath (Join-Path $FullRoot 'workspaces')
}
function Assert-ManagedRootIdentity([string]$FullRoot) {
    $markerPath = Join-Path $FullRoot '.codex-automation-managed'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Fail 'managed root marker is missing' }
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'managed root marker is a reparse point' }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Fail 'managed root marker is malformed' }
    $expected = @('created_at','execution_area_id','managed_by','schema')
    $actual = @($marker.PSObject.Properties.Name | Sort-Object)
    if ((@($expected | Sort-Object) -join '|') -ne ($actual -join '|')) { Fail 'managed root marker fields are not exact' }
    if ([string]$marker.managed_by -cne 'codex-automation' -or (($marker.schema -isnot [int]) -and ($marker.schema -isnot [long])) -or [int64]$marker.schema -ne 1) { Fail 'managed root marker identity is unexpected' }
    if ([string]$marker.execution_area_id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') { Fail 'managed root marker identity is invalid' }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$marker.created_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { Fail 'managed root marker timestamp is invalid' }
}
function Assert-NoReparsePath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'reparse point in workspace path' }
        $parentProperty = $item.PSObject.Properties['Parent']
        if ($null -eq $parentProperty) { break }
        $item = $parentProperty.Value
    }
}
function Assert-NoReparseDescendants([string]$Path) {
    Assert-NoReparsePath $Path
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'reparse point in workspace contents' }
    }
}
function Assert-RecoveryManagedArea([string]$FullRoot, [string]$TargetWorkspacePath) {
    Assert-ManagedWorkspaceBoundary $FullRoot
    Assert-ManagedRootIdentity $FullRoot
    Assert-InactiveRunState $FullRoot
    foreach ($directoryName in @('state','codex-home','temp')) {
        $directory = Join-Path $FullRoot $directoryName
        Assert-NoReparseDescendants $directory
        if (@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -ne 0) { Fail "$directoryName contains recovery residue" }
    }
    Assert-NoReparseDescendants (Join-Path $FullRoot 'logs')
    $workspaceRoot = Join-Path $FullRoot 'workspaces'
    $entries = @(Get-ChildItem -LiteralPath $workspaceRoot -Force -ErrorAction Stop)
    if ($entries.Count -ne 1 -or $entries[0].FullName -cne (FullPath $TargetWorkspacePath)) { Fail 'workspace area contains unexpected residue' }
    Assert-NoReparseDescendants $TargetWorkspacePath
}
function Normalize-Repository([string]$Value) {
    $normalized = $Value.Trim() -replace '\.git$',''
    if ($normalized -match 'github\.com[:/](?<repo>[^/]+/[^/]+)$') { return $Matches.repo }
    return $normalized
}
function Get-WorkspacePath([string]$FullRoot) {
    $workspaceRoot = FullPath (Join-Path $FullRoot 'workspaces')
    $path = FullPath (Join-Path $workspaceRoot $WorkspaceName)
    if (-not $path.StartsWith($workspaceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Fail 'workspace escapes managed workspaces' }
    return $path
}
function Get-MarkerPath([string]$WorkspacePath) { return Join-Path $WorkspacePath '.codex-workspace-owned.json' }
function Read-OwnershipMarker([string]$WorkspacePath) {
    $markerPath = Get-MarkerPath $WorkspacePath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Fail 'workspace ownership marker is missing' }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch { Fail 'workspace ownership marker is malformed' }
    $expected = @('base_sha','execution_id','repository','schema','workspace_name')
    $actual = @($marker.PSObject.Properties.Name | Sort-Object)
    if ((@($expected | Sort-Object) -join '|') -ne ($actual -join '|')) { Fail 'workspace ownership marker fields are not exact' }
    if ((($marker.schema -isnot [int]) -and ($marker.schema -isnot [long])) -or [int64]$marker.schema -ne $WorkspaceSchema -or [string]$marker.execution_id -cne $ExecutionId -or [string]$marker.workspace_name -cne $WorkspaceName -or [string]$marker.repository -cne $ExpectedRepository -or [string]$marker.base_sha -cne $BaseSha) { Fail 'workspace ownership marker does not match requested execution' }
    return $marker
}
function Invoke-Git([string[]]$Arguments) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git @Arguments 1>$null 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0) { Fail "git operation failed ($($Arguments[0]))" }
}
function Assert-CommitObject([string]$WorkspacePath, [string]$Sha) {
    $type = (& git -C $WorkspacePath cat-file -t "$Sha`^{commit}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'commit') { Fail 'expected final SHA is not an existing commit object' }
}
function Assert-RepositoryState([string]$WorkspacePath, [switch]$AllowOwnershipMarker, [switch]$AllowSingleDirtyPayload, [switch]$AllowRecoveryDirty) {
    $actualRemote = (& git -C $WorkspacePath remote get-url origin 2>$null).Trim()
    if ((Normalize-Repository $actualRemote) -cne $ExpectedRepository) { Fail 'cloned repository identity is unexpected' }
    $head = (& git -C $WorkspacePath rev-parse HEAD 2>$null).Trim()
    $expectedHead = $BaseSha.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFinalSha)) {
        Assert-CommitObject $WorkspacePath $ExpectedFinalSha.ToLowerInvariant()
        $parents = @((& git -C $WorkspacePath show -s --format=%P $ExpectedFinalSha.ToLowerInvariant() 2>$null).Trim() -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($LASTEXITCODE -ne 0 -or $parents.Count -ne 1 -or $parents[0] -cne $BaseSha.ToLowerInvariant()) { Fail 'expected final SHA is not a direct child of expected base SHA' }
        $expectedHead = $ExpectedFinalSha.ToLowerInvariant()
    }
    if ($head -cne $expectedHead) { Fail 'workspace HEAD does not match expected immutable commit SHA' }
    $status = @(& git -C $WorkspacePath status --porcelain=v1 --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($AllowOwnershipMarker) {
        $status = @($status | Where-Object { $_ -ne '?? .codex-workspace-owned.json' })
    }
    if ($status.Count -eq 0) { return }
    if ($AllowRecoveryDirty) {
        foreach ($entry in $status) {
            if ($entry -match '^(?:\?\? |[ MADRCU?!]{2} )(.+)$') {
                $relative = $Matches[1].Trim('"')
                $candidate = Join-Path $WorkspacePath $relative
                if (Test-Path -LiteralPath $candidate) { Assert-NoReparseDescendants $candidate }
            } else { Fail 'workspace status entry is malformed' }
        }
        return
    }
    if (-not $AllowSingleDirtyPayload -or $status.Count -ne 1 -or $status[0] -notmatch '^\?\? (ca-p10-032-validation/validation-[0-9]+\.txt|ca-p10-033-e2e/issue-[1-9][0-9]*\.txt)$') { Fail 'workspace base state is not clean' }
    $payloadPath = Join-Path $WorkspacePath ($status[0].Substring(3))
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { Fail 'failed payload artifact is not a regular file' }
    Assert-NoReparsePath $payloadPath
}
function Assert-SourceState([string]$SourcePath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { Fail 'local source is missing' }
    $sourceFull = FullPath $SourcePath
    $actualRemote = (& git -C $sourceFull remote get-url origin 2>$null).Trim()
    if ((Normalize-Repository $actualRemote) -cne $ExpectedRepository) { Fail 'local source repository identity is unexpected' }
    $head = (& git -C $sourceFull rev-parse HEAD 2>$null).Trim()
    if ($head -cne $BaseSha.ToLowerInvariant()) { Fail 'local source HEAD does not match immutable base SHA' }
    $status = @(& git -C $sourceFull status --porcelain=v1 --untracked-files=all 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($status.Count -ne 0) { Fail 'local source is not clean' }
    return $sourceFull
}
function Assert-ActiveRunState([string]$FullRoot) {
    $statePath = Join-Path (Join-Path $FullRoot 'state') 'current-run.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Fail 'active current-run state is missing' }
    try { $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Fail 'active current-run state is malformed' }
    $expected = @('execution_id','github_run_attempt','github_run_id','repository_id','schema','started_at_utc')
    $actual = @($state.PSObject.Properties.Name | Sort-Object)
    if ((@($expected | Sort-Object) -join '|') -ne ($actual -join '|')) { Fail 'active current-run fields are not exact' }
    if ([int]$state.schema -ne 1 -or [string]$state.execution_id -cne $ExecutionId) { Fail 'active current-run identity does not match execution' }
    if ([string]$state.repository_id -notmatch '^[0-9]+$' -or [string]$state.github_run_id -notmatch '^[0-9]+$' -or [string]$state.github_run_attempt -notmatch '^[0-9]+$') { Fail 'active current-run identity fields are invalid' }
    if ([string]::IsNullOrWhiteSpace([string]$state.started_at_utc)) { Fail 'active current-run timestamp is invalid' }
}
function Assert-InactiveRunState([string]$FullRoot) {
    $statePath = Join-Path (Join-Path $FullRoot 'state') 'current-run.json'
    if (Test-Path -LiteralPath $statePath) { Fail 'inactive cleanup cannot run while current-run state exists' }
}

Assert-Inputs
$fullRoot = FullPath $Root
$workspacePath = Get-WorkspacePath $fullRoot
$workspaceRoot = Split-Path -Parent $workspacePath

if ($Action -eq 'preflight') {
    Invoke-ManagedPreflight $fullRoot
    if (Test-Path -LiteralPath $workspacePath) { Fail 'workspace already exists; refusing reuse' }
    Write-Output 'WORKSPACE_PREFLIGHT_PASSED'
    exit 0
}

if ($Action -eq 'prepare') {
    if ($ActiveRun) { Assert-ManagedWorkspaceBoundary $fullRoot; Assert-ActiveRunState $fullRoot } else { Invoke-ManagedPreflight $fullRoot }
    if (Test-Path -LiteralPath $workspacePath) { Fail 'workspace already exists; refusing reuse or unknown state' }
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null
    try {
        $usingUrlSource = [string]::IsNullOrWhiteSpace($LocalSourcePath)
        if ($usingUrlSource) {
            $cloneSource = $RepositoryUrl
            $cloneRemote = $RepositoryUrl
        } else {
            $cloneSource = Assert-SourceState (FullPath $LocalSourcePath)
            $cloneRemote = (& git -C $cloneSource remote get-url origin 2>$null).Trim()
        }
        Invoke-Git @('clone','--no-local','--no-checkout','--no-tags','--config','credential.helper=','--',$cloneSource,$workspacePath)
        if (-not [string]::IsNullOrWhiteSpace($LocalSourcePath)) { Invoke-Git @('-C',$workspacePath,'remote','set-url','origin',$cloneRemote) }
        if ($usingUrlSource) { Invoke-Git @('-C',$workspacePath,'fetch','--no-tags','--depth','1','origin',$BaseSha) }
        Invoke-Git @('-C',$workspacePath,'checkout','--detach','--force',$BaseSha)
        Assert-RepositoryState $workspacePath
        $marker = [ordered]@{ schema=$WorkspaceSchema; workspace_name=$WorkspaceName; execution_id=$ExecutionId; repository=$ExpectedRepository; base_sha=$BaseSha.ToLowerInvariant() }
        $markerPath = Get-MarkerPath $workspacePath
        $tempMarker = "$markerPath.$([guid]::NewGuid().ToString('N')).tmp"
        try { [IO.File]::WriteAllText($tempMarker, (($marker | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $tempMarker -Destination $markerPath -Force } finally { if (Test-Path -LiteralPath $tempMarker) { Remove-Item -LiteralPath $tempMarker -Force -ErrorAction SilentlyContinue } }
        Write-Output 'WORKSPACE_PREPARED'
        Write-Output "WORKSPACE_PATH=$workspacePath"
        exit 0
    } catch {
        try {
            if (Test-Path -LiteralPath $workspacePath) { Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $workspacePath) { throw 'workspace residue remains after failed prepare' }
        } catch {
            Write-Output 'FAIL_CLOSED'
            throw 'workspace prepare failed and cleanup did not prove residue-free'
        }
        throw
    }
}

Assert-ManagedWorkspaceBoundary $fullRoot
if ($Action -eq 'recover') {
    if ($ActiveRun) { Fail 'recovery cannot run with active-run mode' }
    Assert-ManagedRootIdentity $fullRoot
    Assert-InactiveRunState $fullRoot
    if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) { Fail 'failed workspace is missing' }
    Assert-RecoveryManagedArea $fullRoot $workspacePath
    Read-OwnershipMarker $workspacePath | Out-Null
    Assert-RepositoryState $workspacePath -AllowOwnershipMarker -AllowRecoveryDirty
    try {
        Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $workspacePath) { Fail 'workspace recovery left residue' }
        Invoke-ManagedPreflight $fullRoot
        Write-Output 'WORKSPACE_RECOVERED'
    } catch { Fail 'workspace recovery failed' }
    exit 0
}
if ($ActiveRun) { Assert-ActiveRunState $fullRoot }
if (Test-Path -LiteralPath $workspacePath) { Assert-NoReparsePath $workspacePath }
Read-OwnershipMarker $workspacePath | Out-Null
$allowSingleDirtyPayload = (-not $ActiveRun -and [string]::IsNullOrWhiteSpace($ExpectedFinalSha))
if ($allowSingleDirtyPayload) { Assert-InactiveRunState $fullRoot }
Assert-RepositoryState $workspacePath -AllowOwnershipMarker -AllowSingleDirtyPayload:$allowSingleDirtyPayload
try {
    Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $workspacePath) { Fail 'workspace cleanup left residue' }
    if ($ActiveRun) { Assert-ManagedWorkspaceBoundary $fullRoot } else { Invoke-ManagedPreflight $fullRoot }
    Write-Output 'WORKSPACE_CLEANED'
} catch { Fail 'workspace cleanup failed' }
