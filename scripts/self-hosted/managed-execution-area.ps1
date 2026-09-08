[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ensure', 'preflight')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ManagedBy = 'codex-automation'
$Schema = 1
$MarkerName = '.codex-automation-managed'
$KnownDirectories = @('state', 'workspaces', 'codex-home', 'temp', 'logs')
$SensitiveDirectories = @('workspaces', 'codex-home', 'temp')

function Fail([string]$Message) {
    throw "managed execution area preflight failed: $Message"
}

function Get-FullDirectory([string]$Path) {
    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        Fail "invalid root path"
    }
}

function Assert-NoReparseInPath([string]$Path) {
    $full = Get-FullDirectory $Path
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "reparse point in managed path"
        }
        $item = $item.Parent
    }
}

function Assert-Directory([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "$Description is missing"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a reparse point"
    }
    Assert-NoReparseInPath $Path
}

function Write-AtomicText([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $temp = Join-Path $directory (".{0}.{1}.tmp" -f $leaf, ([guid]::NewGuid().ToString('N')))
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream = [System.IO.FileStream]::new(
            $temp,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $Path) {
            Fail "refusing to replace existing immutable marker"
        }
        [System.IO.File]::Move($temp, $Path)
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-Marker([string]$RootPath) {
    $marker = [ordered]@{
        managed_by = $ManagedBy
        schema = $Schema
        execution_area_id = [guid]::NewGuid().ToString()
        created_at = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    Write-AtomicText (Join-Path $RootPath $MarkerName) "$marker`n"
}

function Read-Marker([string]$RootPath) {
    $path = Join-Path $RootPath $MarkerName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "managed marker is missing"
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "managed marker is a reparse point"
    }
    try {
        $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Fail "managed marker is malformed"
    }
    $names = @($marker.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @('created_at', 'execution_area_id', 'managed_by', 'schema')
    if (@(Compare-Object $names $expectedNames).Count -ne 0) {
        Fail "managed marker fields are not exact"
    }
    if ([string]$marker.managed_by -cne $ManagedBy) { Fail "managed_by is unexpected" }
    if (($marker.schema -isnot [int]) -and ($marker.schema -isnot [long])) { Fail "schema is not an integer" }
    if ([int64]$marker.schema -ne $Schema) { Fail "schema is unsupported" }
    $executionAreaId = [string]$marker.execution_area_id
    if ($executionAreaId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') { Fail "execution area identity is not a GUID" }
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($executionAreaId, [ref]$guid)) { Fail "execution area identity is invalid" }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$marker.created_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        Fail "created_at is invalid"
    }
    return $marker
}

function Assert-NoUnexpectedRootEntries([string]$RootPath) {
    $actual = @(Get-ChildItem -LiteralPath $RootPath -Force -ErrorAction Stop | ForEach-Object { $_.Name } | Sort-Object)
    $expected = @($MarkerName) + $KnownDirectories | Sort-Object
    foreach ($entry in $actual) {
        if ($expected -notcontains $entry) {
            Fail "execution root contains unexpected entries"
        }
    }
}

function Assert-ExpectedRootEntries([string]$RootPath) {
    Assert-NoUnexpectedRootEntries $RootPath
    $actual = @(Get-ChildItem -LiteralPath $RootPath -Force -ErrorAction Stop | ForEach-Object { $_.Name } | Sort-Object)
    $expected = @($MarkerName) + $KnownDirectories | Sort-Object
    if (@(Compare-Object $actual $expected).Count -ne 0) {
        Fail "execution root is missing a required entry"
    }
}

function Assert-NoAtomicResidue([string]$RootPath) {
    $patterns = @('.codex-automation-managed.*.tmp', '*.tmp')
    foreach ($directory in @($RootPath) + ($KnownDirectories | ForEach-Object { Join-Path $RootPath $_ })) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($pattern in $patterns) {
            if (@(Get-ChildItem -LiteralPath $directory -Force -File -Filter $pattern -ErrorAction Stop).Count -gt 0) {
                Fail "atomic temporary residue exists"
            }
        }
    }
}

function Assert-CleanState([string]$RootPath) {
    $state = Join-Path $RootPath 'state'
    $current = Join-Path $state 'current-run.json'
    if (Test-Path -LiteralPath $current) { Fail "current-run state exists" }
    if (@(Get-ChildItem -LiteralPath $state -Force -ErrorAction Stop).Count -gt 0) {
        Fail "state contains residue"
    }
    foreach ($directoryName in $SensitiveDirectories) {
        $directory = Join-Path $RootPath $directoryName
        if (@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -gt 0) {
            Fail "$directoryName contains residue"
        }
    }
    Assert-NoAtomicResidue $RootPath
}

function Ensure-Area {
    $fullRoot = Get-FullDirectory $Root
    $rootExists = Test-Path -LiteralPath $fullRoot -PathType Container
    if (-not $rootExists) {
        New-Item -ItemType Directory -Path $fullRoot -Force | Out-Null
        Assert-NoReparseInPath $fullRoot
        New-Marker $fullRoot
    } else {
        Assert-Directory $fullRoot 'execution root'
        Read-Marker $fullRoot | Out-Null
        Assert-NoUnexpectedRootEntries $fullRoot
    }
    foreach ($directoryName in $KnownDirectories) {
        $directory = Join-Path $fullRoot $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            if (Test-Path -LiteralPath $directory) { Fail "$directoryName is not a directory" }
            New-Item -ItemType Directory -Path $directory | Out-Null
        }
        Assert-Directory $directory $directoryName
    }
    Assert-ExpectedRootEntries $fullRoot
    Assert-CleanState $fullRoot
    Write-Output 'managed execution area ready'
}

function Preflight-Area {
    $fullRoot = Get-FullDirectory $Root
    Assert-Directory $fullRoot 'execution root'
    Read-Marker $fullRoot | Out-Null
    Assert-ExpectedRootEntries $fullRoot
    foreach ($directoryName in $KnownDirectories) {
        Assert-Directory (Join-Path $fullRoot $directoryName) $directoryName
    }
    Assert-CleanState $fullRoot
    Write-Output 'managed execution area preflight passed'
}

if ($Action -eq 'ensure') { Ensure-Area } else { Preflight-Area }
