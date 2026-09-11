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

    $dirtyUnrelated = New-Workspace 'dirty-unrelated'
    Set-Content -LiteralPath (Join-Path $dirtyUnrelated.Path 'unrelated.txt') -Value 'unrelated' -NoNewline
    Assert-Fails 'dirty unrelated cleanup' { Invoke-Lifecycle cleanup $dirtyUnrelated.Root }
    if (-not (Test-Path -LiteralPath $dirtyUnrelated.Path)) { throw 'dirty unrelated cleanup removed workspace' }

    $markerMismatch = New-Workspace 'marker-mismatch'
    $markerPath = Join-Path $markerMismatch.Path '.codex-workspace-owned.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw
    Set-Content -LiteralPath $markerPath -Value ($marker.Replace($baseSha, ('0' * 40))) -NoNewline
    Assert-Fails 'ownership marker mismatch' { Invoke-Lifecycle cleanup $markerMismatch.Root }

    Write-Output 'PASS workspace lifecycle trusted-final and fail-closed cases'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
