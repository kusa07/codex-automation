[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Prepare','Cleanup')][string]$Action)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NonReparse([string]$Path) {
    if ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Google Cloud run config path contains a reparse point.'
    }
}
function Assert-RunIdentity {
    foreach ($name in @('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_REPOSITORY_ID','RUNNER_TEMP')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing run identity field: $name" }
    }
    foreach ($name in @('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_REPOSITORY_ID')) {
        if ([Environment]::GetEnvironmentVariable($name) -notmatch '^[1-9][0-9]*$') { throw "Invalid run identity field: $name" }
    }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-20') { throw 'Google Cloud runtime preparation requires NETWORK SERVICE.' }
    $temp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
    if ((Split-Path -Leaf $temp) -cne '_temp' -or (Split-Path -Leaf (Split-Path -Parent $temp)) -cne '_work') { throw 'RUNNER_TEMP is outside the canonical runner layout.' }
    $runnerRoot = Split-Path -Parent (Split-Path -Parent $temp)
    if ((Split-Path -Leaf $runnerRoot) -cne ('repo-' + $env:GITHUB_REPOSITORY_ID)) { throw 'RUNNER_TEMP repository identity differs from the runner directory.' }
    foreach ($path in @($runnerRoot,(Join-Path $runnerRoot '_work'),$temp)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Canonical RUNNER_TEMP ancestor is missing.' }
        Assert-NonReparse $path
    }
    $temp
}
function Assert-NoGcloudSiblingResidue([string]$TempPath) {
    # RUNNER_TEMP is reused by the repository runner. A different run's
    # credential/config residue is a security stop, not something to adopt or
    # delete while preparing this run.
    $siblings = @(Get-ChildItem -LiteralPath $TempPath -Force -ErrorAction Stop |
        Where-Object { $_.Name -like 'codex-gcloud-*' })
    if ($siblings.Count -ne 0) { throw 'Google Cloud config namespace contains stale run residue.' }
}
function Assert-ConfigAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { throw 'Google Cloud config ACL inheritance is enabled.' }
    $expected = @{'S-1-5-20'='Modify';'S-1-5-18'='FullControl';'S-1-5-32-544'='FullControl'}
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 3) { throw 'Google Cloud config ACL has unexpected access rules.' }
    foreach ($rule in $rules) {
        $sid = [string]$rule.IdentityReference.Value
        $required = [Security.AccessControl.FileSystemRights]::$($expected[$sid]) -bor [Security.AccessControl.FileSystemRights]::Synchronize
        if (-not $expected.ContainsKey($sid) -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IsInherited -or [int]$rule.FileSystemRights -ne [int]$required) {
            throw 'Google Cloud config ACL has unexpected access rights.'
        }
    }
}

$temp = Assert-RunIdentity
$name = 'codex-gcloud-{0}-{1}' -f $env:GITHUB_RUN_ID,$env:GITHUB_RUN_ATTEMPT
$config = Join-Path $temp $name
if ([IO.Path]::GetFullPath($config) -ine [IO.Path]::Combine($temp,$name)) { throw 'Google Cloud config path is not canonical.' }
$marker = Join-Path $config '.codex-gcloud-owned.json'
if ($Action -eq 'Prepare') {
    Assert-NoGcloudSiblingResidue $temp
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $python = Join-Path $programFiles 'Python313\python.exe'
    Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'phase12b-system-python.psm1') -Force
    $state = Get-Phase12BSystemPythonState
    if ($state.Classification -ne 'EXACT' -or [string]$state.Path -ine $python) { throw 'System Python is not the exact verified host dependency.' }
    New-Item -ItemType Directory -Path $config -ErrorAction Stop | Out-Null
    try {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($pair in @(@('S-1-5-20','Modify'),@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier($pair[0])
        $rights = [Security.AccessControl.FileSystemRights]::$($pair[1])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,$rights,'ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $config -AclObject $acl -ErrorAction Stop
    Assert-NonReparse $config
    Assert-ConfigAcl $config
    [IO.File]::WriteAllText($marker,(@{schema=1;run_id=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;repository_id=$env:GITHUB_REPOSITORY_ID;path=$config}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if (-not (Test-Path -LiteralPath $env:GITHUB_ENV -PathType Leaf)) { throw 'GitHub environment file is unavailable.' }
    Add-Content -LiteralPath $env:GITHUB_ENV -Value "CLOUDSDK_PYTHON=$python" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_ENV -Value "CLOUDSDK_CONFIG=$config" -Encoding utf8
    # The Service must not inherit a profile- or machine-defined Python search
    # path/Cloud SDK interpreter flag into the job's gcloud process.
    foreach ($name in @('PYTHONPATH','PYTHONHOME','CLOUDSDK_PYTHON_SITEPACKAGES','CLOUDSDK_PYTHON_ARGS')) {
        Add-Content -LiteralPath $env:GITHUB_ENV -Value ($name + '=') -Encoding utf8
    }
    Add-Content -LiteralPath $env:GITHUB_ENV -Value 'PYTHONNOUSERSITE=1' -Encoding utf8
    } catch {
        # Before the ownership marker exists, only this invocation's newly
        # created, still-empty directory may be removed. Any other residue is
        # deliberately left for explicit recovery; the always-run cleanup will
        # handle a complete owned marker.
        if ((Test-Path -LiteralPath $config -PathType Container) -and -not (Test-Path -LiteralPath $marker)) {
            Assert-NonReparse $config
            if (@(Get-ChildItem -LiteralPath $config -Force -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $config -Force -ErrorAction Stop
            }
        }
        throw
    }
    'GCLOUD_CONFIG_PREPARED=PASS'
    return
}
if (-not (Test-Path -LiteralPath $config)) { 'GCLOUD_CONFIG_CLEANUP=NOOP'; return }
if (-not (Test-Path -LiteralPath $config -PathType Container)) { throw 'Google Cloud config target is not a directory.' }
Assert-NonReparse $config
Assert-ConfigAcl $config
if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Google Cloud config ownership marker is missing.' }
Assert-NonReparse $marker
try { $owned = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Google Cloud config ownership marker is malformed.' }
if ([string]$owned.schema -cne '1' -or [string]$owned.run_id -cne $env:GITHUB_RUN_ID -or
    [string]$owned.attempt -cne $env:GITHUB_RUN_ATTEMPT -or [string]$owned.repository_id -cne $env:GITHUB_REPOSITORY_ID -or
    [string]$owned.path -ine $config) { throw 'Google Cloud config ownership marker mismatch.' }
$contents = @(Get-ChildItem -LiteralPath $config -Force -Recurse -ErrorAction Stop)
foreach ($item in $contents) { Assert-NonReparse $item.FullName }
Remove-Item -LiteralPath $config -Recurse -Force -ErrorAction Stop
if (Test-Path -LiteralPath $config) { throw 'Google Cloud config residue remains after cleanup.' }
'GCLOUD_CONFIG_CLEANUP=PASS'
