$ErrorActionPreference = 'Stop'

# Values arrive through environment variables. Never construct a PowerShell
# command line from a repository-controlled path.
$root = $env:CODEX_REPARSE_ROOT
$relative = $env:CODEX_REPARSE_RELATIVE
if ([string]::IsNullOrWhiteSpace($root)) { throw 'Workspace root is missing.' }
$root = [IO.Path]::GetFullPath($root)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Workspace root is not a directory.' }

function Assert-AttributesNotReparse([IO.FileAttributes]$attributes) {
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A workspace path is a reparse point.'
    }
}

function Test-IsAllowedMissing([Exception]$failure, [bool]$allowMissing) {
    return $allowMissing -and ($failure -is [IO.FileNotFoundException] -or $failure -is [IO.DirectoryNotFoundException])
}

function Assert-NotReparse([string]$path, [bool]$allowMissing) {
    try {
        $attributes = [IO.File]::GetAttributes($path)
    } catch {
        $failure = $_.Exception
        while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
        if (Test-IsAllowedMissing $failure $allowMissing) {
            return
        }
        throw
    }
    Assert-AttributesNotReparse $attributes
}

$ancestor = $root
while (-not [string]::IsNullOrEmpty($ancestor)) {
    Assert-NotReparse $ancestor $false
    $parent = Split-Path -Path $ancestor -Parent
    if ($parent -eq $ancestor) { break }
    $ancestor = $parent
}
if ([string]::IsNullOrEmpty($relative)) { exit 0 }
if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or $relative.Contains(':')) {
    throw 'Relative path is invalid.'
}
$current = $root
foreach ($component in ($relative -split '/')) {
    if ([string]::IsNullOrEmpty($component) -or $component -eq '.' -or $component -eq '..') {
        throw 'Relative path component is invalid.'
    }
    $current = Join-Path -Path $current -ChildPath $component
    Assert-NotReparse $current $true
}
