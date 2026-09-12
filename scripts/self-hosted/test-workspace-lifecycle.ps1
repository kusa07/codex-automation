$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$lifecycle = Join-Path $scriptDir 'workspace-lifecycle.ps1'
$managedArea = Join-Path $scriptDir 'managed-execution-area.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ca-p10-032-workspace-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$sourceRepo = Join-Path $testRoot 'source'
$baseSha = $null
$finalSha = $null

function Invoke-Git([string]$WorkingDirectory, [string[]]$Arguments) {
    Push-Location $WorkingDirectory
    try { & git @Arguments | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git failed: $($Arguments -join ' ')" } }
    finally { Pop-Location }
}
function Git-Value([string]$WorkingDirectory, [string[]]$Arguments) {
    Push-Location $WorkingDirectory
    try { $value = (& git @Arguments 2>$null).Trim(); if ($LASTEXITCODE -ne 0) { throw "git failed: $($Arguments -join ' ')" }; return $value }
    finally { Pop-Location }
}
function Invoke-Lifecycle([string]$Action, [string]$Root, [string]$FinalSha = $null) {
    $sourceArgs = @{}
    if ($Action -eq 'prepare') { $sourceArgs = @{ LocalSourcePath = $sourceRepo } }
    if ($null -ne $FinalSha) {
        & $lifecycle -Action $Action -Root $Root -ExpectedRepository 'example/repo' -BaseSha $baseSha -WorkspaceName 'workspace' -ExecutionId (Split-Path -Leaf $Root) @sourceArgs -ExpectedFinalSha $FinalSha | Out-Null
    } else {
        & $lifecycle -Action $Action -Root $Root -ExpectedRepository 'example/repo' -BaseSha $baseSha -WorkspaceName 'workspace' -ExecutionId (Split-Path -Leaf $Root) @sourceArgs | Out-Null
    }
}
function New-Workspace([string]$Name) {
    $root = Join-Path $testRoot $Name
    & $managedArea -Action ensure -Root $root | Out-Null
    Invoke-Lifecycle prepare $root
    return @{ Root = $root; Path = Join-Path $root 'workspaces\workspace' }
}
function Assert-Fails([string]$Name, [scriptblock]$Action) {
    try { & $Action; throw "$Name unexpectedly succeeded" } catch { if ($_.Exception.Message -eq "$Name unexpectedly succeeded") { throw } }
}

try {
    New-Item -ItemType Directory -Path $sourceRepo -Force | Out-Null
    Invoke-Git $sourceRepo @('init', '--quiet')
    Invoke-Git $sourceRepo @('config', 'user.name', 'CA-P10-032 test')
    Invoke-Git $sourceRepo @('config', 'user.email', 'ca-p10-032-test@example.invalid')
    Invoke-Git $sourceRepo @('remote', 'add', 'origin', 'https://github.com/example/repo.git')
    Set-Content -LiteralPath (Join-Path $sourceRepo 'tracked.txt') -Value 'base' -NoNewline
    Invoke-Git $sourceRepo @('add', 'tracked.txt')
    Invoke-Git $sourceRepo @('commit', '--quiet', '-m', 'base')
    $baseSha = Git-Value $sourceRepo @('rev-parse', 'HEAD')
    Add-Content -LiteralPath (Join-Path $sourceRepo 'tracked.txt') -Value 'final'
    Invoke-Git $sourceRepo @('add', 'tracked.txt')
    Invoke-Git $sourceRepo @('commit', '--quiet', '-m', 'final')
    $finalSha = Git-Value $sourceRepo @('rev-parse', 'HEAD')
    Invoke-Git $sourceRepo @('branch', 'final', $finalSha)
    Invoke-Git $sourceRepo @('checkout', '--quiet', $baseSha)
    Set-Content -LiteralPath (Join-Path $sourceRepo 'unrelated.txt') -Value 'unrelated final' -NoNewline
    Invoke-Git $sourceRepo @('add', 'unrelated.txt')
    Invoke-Git $sourceRepo @('commit', '--quiet', '-m', 'unrelated final')
    $unrelatedFinalSha = Git-Value $sourceRepo @('rev-parse', 'HEAD')
    Invoke-Git $sourceRepo @('branch', 'unrelated-final', $unrelatedFinalSha)
    Invoke-Git $sourceRepo @('checkout', '--quiet', $unrelatedFinalSha)
    Set-Content -LiteralPath (Join-Path $sourceRepo 'unrelated-2.txt') -Value 'unrelated second parent' -NoNewline
    Invoke-Git $sourceRepo @('add', 'unrelated-2.txt')
    Invoke-Git $sourceRepo @('commit', '--quiet', '-m', 'unrelated second final')
    $unrelatedFinalSha = Git-Value $sourceRepo @('rev-parse', 'HEAD')
    Invoke-Git $sourceRepo @('branch', 'unrelated-final-2', $unrelatedFinalSha)
    Invoke-Git $sourceRepo @('checkout', '--quiet', $baseSha)

    $legacy = New-Workspace 'legacy'
    Invoke-Lifecycle cleanup $legacy.Root
    if (Test-Path -LiteralPath $legacy.Path) { throw 'legacy cleanup left workspace residue' }

    $trusted = New-Workspace 'trusted-final'
    Invoke-Git $trusted.Path @('checkout', '--quiet', $finalSha)
    Invoke-Lifecycle cleanup $trusted.Root $finalSha
    if (Test-Path -LiteralPath $trusted.Path) { throw 'trusted-final cleanup left workspace residue' }

    $missing = New-Workspace 'missing-final'
    Invoke-Git $missing.Path @('checkout', '--quiet', $finalSha)
    Assert-Fails 'missing final SHA' { Invoke-Lifecycle cleanup $missing.Root }

    $mismatched = New-Workspace 'mismatched-final'
    Invoke-Git $mismatched.Path @('checkout', '--quiet', $finalSha)
    Assert-Fails 'mismatched final SHA' { Invoke-Lifecycle cleanup $mismatched.Root $baseSha }

    $unrelated = New-Workspace 'unrelated-final'
    Invoke-Git $unrelated.Path @('checkout', '--quiet', $unrelatedFinalSha)
    Assert-Fails 'unrelated final SHA' { Invoke-Lifecycle cleanup $unrelated.Root $unrelatedFinalSha }
    if (-not (Test-Path -LiteralPath $unrelated.Path)) { throw 'unrelated final cleanup removed workspace' }

    $nonHex = New-Workspace 'nonhex-final'
    Assert-Fails 'non-hex final SHA' { Invoke-Lifecycle cleanup $nonHex.Root 'not-a-sha' }

    $dirty = New-Workspace 'dirty-final'
    Invoke-Git $dirty.Path @('checkout', '--quiet', $finalSha)
    Set-Content -LiteralPath (Join-Path $dirty.Path 'unexpected.txt') -Value 'unexpected' -NoNewline
    Assert-Fails 'dirty trusted-final cleanup' { Invoke-Lifecycle cleanup $dirty.Root $finalSha }

    $dirtyOwned = New-Workspace 'dirty-owned'
    $payloadDirectory = Join-Path $dirtyOwned.Path 'ca-p10-032-validation'
    New-Item -ItemType Directory -Path $payloadDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $payloadDirectory 'validation-12345.txt') -Value 'failed payload' -NoNewline
    Invoke-Lifecycle cleanup $dirtyOwned.Root
    if (Test-Path -LiteralPath $dirtyOwned.Path) { throw 'dirty-owned cleanup left workspace residue' }

    $dirtyIssue = New-Workspace 'dirty-issue-owned'
    $issuePayloadDirectory = Join-Path $dirtyIssue.Path 'ca-p10-033-e2e'
    New-Item -ItemType Directory -Path $issuePayloadDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $issuePayloadDirectory 'issue-9.txt') -Value 'CA-P10-033 E2E validation from Issue #9' -NoNewline
    Invoke-Lifecycle cleanup $dirtyIssue.Root
    if (Test-Path -LiteralPath $dirtyIssue.Path) { throw 'dirty-issue-owned cleanup left workspace residue' }

    $dirtyUnrelated = New-Workspace 'dirty-unrelated'
    Set-Content -LiteralPath (Join-Path $dirtyUnrelated.Path 'unrelated.txt') -Value 'unrelated' -NoNewline
    Assert-Fails 'dirty unrelated cleanup' { Invoke-Lifecycle cleanup $dirtyUnrelated.Root }
    if (-not (Test-Path -LiteralPath $dirtyUnrelated.Path)) { throw 'dirty unrelated cleanup removed workspace' }

    $markerMismatch = New-Workspace 'marker-mismatch'
    $markerPath = Join-Path $markerMismatch.Path '.codex-workspace-owned.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw
    Set-Content -LiteralPath $markerPath -Value ($marker.Replace($baseSha, ('0' * 40))) -NoNewline
    Assert-Fails 'ownership marker mismatch' { Invoke-Lifecycle cleanup $markerMismatch.Root }

    $recover = New-Workspace 'recover-valid'
    Set-Content -LiteralPath (Join-Path $recover.Path 'unrelated.txt') -Value 'failed run residue' -NoNewline
    Set-Content -LiteralPath (Join-Path $recover.Root 'logs\recovery.log') -Value 'sanitized diagnostic' -NoNewline
    Invoke-Lifecycle recover $recover.Root
    if (Test-Path -LiteralPath $recover.Path) { throw 'valid recovery left workspace residue' }

    $residue = New-Workspace 'recover-managed-residue'
    Set-Content -LiteralPath (Join-Path $residue.Root 'temp\unexpected.txt') -Value 'ambiguous residue' -NoNewline
    Assert-Fails 'managed-area residue recovery' { Invoke-Lifecycle recover $residue.Root }
    if (-not (Test-Path -LiteralPath $residue.Path)) { throw 'managed-area residue recovery removed workspace' }

    $active = New-Workspace 'recover-active'
    $activeState = [ordered]@{ schema = 1; execution_id = 'recover-active'; github_run_attempt = '1'; github_run_id = '2'; repository_id = '3'; started_at_utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
    Set-Content -LiteralPath (Join-Path $active.Root 'state\current-run.json') -Value $activeState -NoNewline
    Assert-Fails 'active recovery' { Invoke-Lifecycle recover $active.Root }
    if (-not (Test-Path -LiteralPath $active.Path)) { throw 'active recovery removed workspace' }

    $repoMismatch = New-Workspace 'recover-repo-mismatch'
    $repoMarkerPath = Join-Path $repoMismatch.Path '.codex-workspace-owned.json'
    $repoMarker = Get-Content -LiteralPath $repoMarkerPath -Raw
    Set-Content -LiteralPath $repoMarkerPath -Value ($repoMarker.Replace('example/repo', 'other/repo')) -NoNewline
    Assert-Fails 'repository mismatch recovery' { Invoke-Lifecycle recover $repoMismatch.Root }
    if (-not (Test-Path -LiteralPath $repoMismatch.Path)) { throw 'repository mismatch recovery removed workspace' }

    $baseMismatch = New-Workspace 'recover-base-mismatch'
    $baseMarkerPath = Join-Path $baseMismatch.Path '.codex-workspace-owned.json'
    $baseMarker = Get-Content -LiteralPath $baseMarkerPath -Raw
    Set-Content -LiteralPath $baseMarkerPath -Value ($baseMarker.Replace($baseSha, ('1' * 40))) -NoNewline
    Assert-Fails 'base mismatch recovery' { Invoke-Lifecycle recover $baseMismatch.Root }

    $rootMarkerMismatch = New-Workspace 'recover-root-marker-mismatch'
    $rootMarkerPath = Join-Path $rootMarkerMismatch.Root '.codex-automation-managed'
    Set-Content -LiteralPath $rootMarkerPath -Value '{}' -NoNewline
    Assert-Fails 'managed root marker recovery' { Invoke-Lifecycle recover $rootMarkerMismatch.Root }

    $rootSchemaString = New-Workspace 'recover-root-schema-string'
    $rootSchemaPath = Join-Path $rootSchemaString.Root '.codex-automation-managed'
    $rootSchema = Get-Content -LiteralPath $rootSchemaPath -Raw
    Set-Content -LiteralPath $rootSchemaPath -Value ($rootSchema.Replace('"schema":1', '"schema":"1"')) -NoNewline
    Assert-Fails 'managed root schema string recovery' { Invoke-Lifecycle recover $rootSchemaString.Root }

    $ownershipSchemaString = New-Workspace 'recover-ownership-schema-string'
    $ownershipSchemaPath = Join-Path $ownershipSchemaString.Path '.codex-workspace-owned.json'
    $ownershipSchema = Get-Content -LiteralPath $ownershipSchemaPath -Raw
    Set-Content -LiteralPath $ownershipSchemaPath -Value ($ownershipSchema.Replace('"schema":1', '"schema":"1"')) -NoNewline
    Assert-Fails 'ownership schema string recovery' { Invoke-Lifecycle recover $ownershipSchemaString.Root }

    $executionMismatch = New-Workspace 'recover-execution-mismatch'
    $executionMarkerPath = Join-Path $executionMismatch.Path '.codex-workspace-owned.json'
    $executionMarker = Get-Content -LiteralPath $executionMarkerPath -Raw
    Set-Content -LiteralPath $executionMarkerPath -Value ($executionMarker.Replace('recover-execution-mismatch', 'different-execution')) -NoNewline
    Assert-Fails 'execution mismatch recovery' { Invoke-Lifecycle recover $executionMismatch.Root }

    $malformed = New-Workspace 'recover-malformed-marker'
    Set-Content -LiteralPath (Join-Path $malformed.Path '.codex-workspace-owned.json') -Value '{' -NoNewline
    Assert-Fails 'malformed marker recovery' { Invoke-Lifecycle recover $malformed.Root }

    $reparse = New-Workspace 'recover-reparse'
    $linkPath = Join-Path $reparse.Path 'link'
    $linkKind = $null
    try { New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourceRepo -ErrorAction Stop | Out-Null; $linkKind = 'symbolic link' } catch { }
    if ($null -eq $linkKind) {
        try { New-Item -ItemType Junction -Path $linkPath -Target $sourceRepo -ErrorAction Stop | Out-Null; $linkKind = 'junction' } catch { }
    }
    if ($null -ne $linkKind) {
        if (((Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'reparse fixture did not create a reparse point' }
        Assert-Fails 'reparse recovery' { Invoke-Lifecycle recover $reparse.Root }
        if (-not (Test-Path -LiteralPath $reparse.Path)) { throw 'reparse recovery removed workspace' }
    } else { Write-Output 'SKIP reparse fixture (symbolic links and junctions unavailable)' }

    $escape = New-Workspace 'recover-escape'
    $escapeMarkerPath = Join-Path $escape.Path '.codex-workspace-owned.json'
    $escapeMarker = Get-Content -LiteralPath $escapeMarkerPath -Raw
    Set-Content -LiteralPath $escapeMarkerPath -Value ($escapeMarker.Replace('workspace', '..\outside')) -NoNewline
    Assert-Fails 'workspace identity escape recovery' { Invoke-Lifecycle recover $escape.Root }
    if (-not (Test-Path -LiteralPath $escape.Path)) { throw 'workspace escape recovery removed workspace' }

    Write-Output 'PASS workspace lifecycle trusted-final and fail-closed cases'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
