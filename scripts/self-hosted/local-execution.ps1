[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('run', 'preflight')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$RepositoryId,
    [string]$GithubRunId,
    [string]$GithubRunAttempt,
    [string]$PayloadPath,
    [string[]]$PayloadArgument = @(),
    [int]$PayloadArgumentCount = 0,
    [string]$PayloadArgumentPrefix,
    [switch]$Inert
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Schema = 1
$StateName = 'current-run.json'
$ManagedAreaHelper = Join-Path $PSScriptRoot 'managed-execution-area.ps1'
$RunnerSidValue = 'S-1-5-21-1522072177-46615327-2561548676-1001'
function Fail([string]$Message) { Write-Output 'FAIL_CLOSED'; throw "local execution failed closed: $Message" }
function Get-FullDirectory([string]$Path) { try { return [System.IO.Path]::GetFullPath($Path) } catch { Fail 'invalid execution root' } }
function Assert-Input([string]$Value, [string]$Name) { if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[0-9]+$') { Fail "$Name is invalid" } }
function Get-ExecutionId { Assert-Input $RepositoryId 'repository_id'; Assert-Input $GithubRunId 'github_run_id'; Assert-Input $GithubRunAttempt 'github_run_attempt'; return "repo-$RepositoryId-run-$GithubRunId-attempt-$GithubRunAttempt" }
function Invoke-AreaPreflight([string]$FullRoot) { & $ManagedAreaHelper -Action preflight -Root $FullRoot | Out-Null }
function Read-Marker([string]$FullRoot) { $path = Join-Path $FullRoot '.codex-automation-managed'; if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail 'managed marker is missing' }; try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { Fail 'managed marker is malformed' } }
function Get-LockName([object]$Marker) { $id = [string]$Marker.execution_area_id; if ($id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') { Fail 'execution area identity is invalid' }; return "Global\CodexAutomation-ExecutionArea-$($id -replace '-', '')" }
function Get-RunnerSid { try { $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { Fail 'current Windows identity is unavailable' }; if ($current -cne $RunnerSidValue) { Fail 'current Windows identity is not the approved runner identity' }; return [System.Security.Principal.SecurityIdentifier]::new($RunnerSidValue) }
function New-MutexSecurity { $sid = Get-RunnerSid; $security = [System.Security.AccessControl.MutexSecurity]::new(); $security.SetAccessRuleProtection($true, $false); $rule = [System.Security.AccessControl.MutexAccessRule]::new($sid, [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow); $security.AddAccessRule($rule); return $security }
function Assert-MutexAcl([System.Threading.Mutex]$Mutex) {
    $target = Get-RunnerSid
    $rules = @($Mutex.GetAccessControl().GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 1) { Fail 'named mutex DACL is not exact' }
    $rule = $rules[0]
    if ($rule.IdentityReference.Value -cne $RunnerSidValue -or $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $rule.MutexRights -ne [System.Security.AccessControl.MutexRights]::FullControl) { Fail 'named mutex DACL is broader than the approved runner identity' }
}
function Open-OrCreateMutex([string]$Name, [ref]$Created) { $mutex = $null; try { $security = New-MutexSecurity; $Created.Value = $false; $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$Created.Value, $security); Assert-MutexAcl $mutex; return $mutex } catch [System.Management.Automation.MethodException] { if ($null -ne $mutex) { $mutex.Dispose() }; Fail 'explicit MutexSecurity constructor is unavailable; refusing weaker ACL fallback' } catch { if ($null -ne $mutex) { $mutex.Dispose() }; Fail 'explicit Mutex ACL setup failed' } }
function Write-AtomicJson([string]$Path, [object]$Object) { $directory = Split-Path -Parent $Path; $leaf = Split-Path -Leaf $Path; $temp = Join-Path $directory (".{0}.{1}.tmp" -f $leaf, ([guid]::NewGuid().ToString('N'))); try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($Object | ConvertTo-Json -Compress -Depth 5) + "`n")); $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough); try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }; if (Test-Path -LiteralPath $Path) { Fail 'current-run state appeared during atomic create' }; [IO.File]::Move($temp, $Path) } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } } }
function Resolve-PayloadArguments {
    if ($PayloadArgumentCount -lt 0) { Fail 'payload argument count is invalid' }
    if ($PayloadArgumentCount -eq 0) {
        if (-not [string]::IsNullOrEmpty($PayloadArgumentPrefix)) { Fail 'payload argument prefix is invalid for an empty argument list' }
        return @($PayloadArgument)
    }
    if ([string]::IsNullOrEmpty($PayloadArgumentPrefix) -or $PayloadArgumentPrefix -notmatch '^[A-Za-z_][A-Za-z0-9_]*_$') { Fail 'payload argument prefix is invalid' }
    $resolved = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $PayloadArgumentCount; $index++) {
        $name = "$PayloadArgumentPrefix$index"
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -eq $value) { Fail "payload argument $index is missing" }
        [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        [void]$resolved.Add($value)
    }
    return $resolved.ToArray()
}
function Invoke-CommandPayload { if ($Inert) { return 0 }; if ([string]::IsNullOrWhiteSpace($PayloadPath)) { Fail 'payload path is required unless inert' }; $arguments = Resolve-PayloadArguments; $resolved = $PayloadPath; if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { try { $resolved = (Get-Command -Name $PayloadPath -CommandType Application -ErrorAction Stop).Source } catch { Fail 'payload path is missing' } }; & $resolved @arguments | Out-Host; $exitCode = $LASTEXITCODE; return [int]$exitCode }
$fullRoot = Get-FullDirectory $Root
if ($Action -eq 'preflight') { Invoke-AreaPreflight $fullRoot; Write-Output 'PREFLIGHT_PASSED'; exit 0 }
$executionId = Get-ExecutionId
$statePath = Join-Path (Join-Path $fullRoot 'state') $StateName
$mutex = $null; $ownsMutex = $false; $stateOwned = $false; $lifecycleError = $null
try {
    Invoke-AreaPreflight $fullRoot; Write-Output 'PREFLIGHT_PASSED'
    $marker = Read-Marker $fullRoot; $lockName = Get-LockName $marker; $created = $false; $mutex = Open-OrCreateMutex $lockName ([ref]$created)
    try { if ($mutex.WaitOne(0)) { $ownsMutex = $true } } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true; Write-Output 'ABANDONED_LOCK_DETECTED'; try { Invoke-AreaPreflight $fullRoot } catch { }; Fail 'abandoned execution mutex detected' }
    if (-not $ownsMutex) { Fail 'execution mutex is busy' }
    Write-Output 'LOCK_ACQUIRED'; Invoke-AreaPreflight $fullRoot
    $state = [ordered]@{ schema=$Schema; execution_id=$executionId; repository_id=$RepositoryId; github_run_id=$GithubRunId; github_run_attempt=$GithubRunAttempt; started_at_utc=[DateTime]::UtcNow.ToString('o') }
    Write-AtomicJson $statePath $state; $stateOwned = $true; Write-Output 'EXECUTION_STARTED'
    $commandExit = Invoke-CommandPayload
    if ($commandExit -ne 0) { throw "payload exited with code $commandExit" }
} catch { $lifecycleError = $_ }
finally {
    $cleanupOk = $true
    if ($stateOwned) { try { Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop } catch { $cleanupOk = $false; Write-Output 'FAIL_CLOSED' } }
    if ($stateOwned) { try { Invoke-AreaPreflight $fullRoot; Write-Output 'CLEANUP_PASSED' } catch { $cleanupOk = $false; Write-Output 'FAIL_CLOSED' } }
    if ($ownsMutex) { try { $mutex.ReleaseMutex() } catch { $cleanupOk = $false; Write-Output 'FAIL_CLOSED' } }
    if ($null -ne $mutex) { $mutex.Dispose() }
    if (-not $cleanupOk) { $lifecycleError = [Exception]::new('cleanup or residual validation failed') }
}
if ($null -ne $lifecycleError) { throw $lifecycleError }
Write-Output 'EXECUTION_FINISHED'; exit 0
