$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5 system Python test failed.' }
    return
}
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'phase12b-system-runtime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'phase12b-system-python.psm1') -Force
function Assert-Throws([scriptblock]$Call,[string]$Message) { try { & $Call | Out-Null } catch { return }; throw $Message }
$policy = Get-Phase12BSystemPythonPolicy
if ($policy.Version -cne '3.13.15' -or $policy.Sha256 -cne 'edec09c4853aeae9ac36efb8c9f95b6b8e2fee65eee56d9767a8b7c69c574403' -or
    $policy.DownloadUrl -cne 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe') { throw 'Python product policy changed.' }
# Exercise the production -c expression through the actual Windows PowerShell
# 5 native process boundary with a test-owned argv recorder. This works on a
# fresh PC before Python bootstrap and never becomes production authority.
$moduleSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'phase12b-system-python.psm1') -Raw -ErrorAction Stop
$probeMatch = [regex]::Match($moduleSource, "(?m)\-I\s+\-c\s+'([^']+)'")
if (-not $probeMatch.Success -or $probeMatch.Groups[1].Value.Contains('"')) { throw 'Python version probe is missing or requires nested quote marshalling.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$probeDirectory = Join-Path $tempRoot ('phase12b-python-argv-' + [guid]::NewGuid().ToString('N'))
if (-not ([IO.Path]::GetFullPath($probeDirectory)).StartsWith($tempRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Test argv directory escaped the temporary root.' }
$stub = Join-Path $probeDirectory 'argv-probe.exe'
$stubSource = @'
using System;
using System.Text;
public static class Phase12BPythonArgvProbe {
    public static int Main(string[] args) {
        if (args.Length != 3 || args[0] != "-I" || args[1] != "-c") return 2;
        Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[2])));
        return 0;
    }
}
'@
try {
    New-Item -ItemType Directory -Path $probeDirectory -ErrorAction Stop | Out-Null
    Add-Type -TypeDefinition $stubSource -OutputAssembly $stub -OutputType ConsoleApplication -ErrorAction Stop
    $encodedArgument = & $stub -I -c $probeMatch.Groups[1].Value
    if ($LASTEXITCODE -ne 0 -or @($encodedArgument).Count -ne 1) { throw 'Windows PowerShell 5 changed the Python probe argv shape.' }
    $actualArgument = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$encodedArgument))
    if ($actualArgument -cne $probeMatch.Groups[1].Value) { throw 'Windows PowerShell 5 changed the Python -c expression.' }
    'PS5_NATIVE_ARGUMENT_PROBE=PASS'
    # Optional execution proof when this development host happens to carry a
    # test interpreter. Missing test tooling is explicitly reported, not PASS.
    $testPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path -LiteralPath $testPython -PathType Leaf) {
        $raw = & $testPython -I -c $probeMatch.Groups[1].Value 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Optional Python execution probe failed.' }
        $parts = ([string]($raw | Select-Object -Last 1)) -split ';'
        if ($parts.Count -ne 3 -or $parts[0] -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
            $parts[1] -cne '64bit' -or [string]$parts[2] -ine [string]$testPython) { throw 'Optional Python execution read-back is malformed.' }
        'ACTUAL_PYTHON_PS5_PROBE=PASS'
    } else { 'ACTUAL_PYTHON_PS5_PROBE=SKIPPED_NO_TEST_INTERPRETER' }
} finally {
    if (Test-Path -LiteralPath $probeDirectory) {
        foreach ($item in @(Get-ChildItem -LiteralPath $probeDirectory -Force -Recurse -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Test argv directory contains a reparse point; manual cleanup required.' }
        }
        Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction Stop
    }
}
$exact = [pscustomobject]@{DirectoryPresent=$true;DirectoryIsContainer=$true;DirectoryNonReparse=$true;LeafPresent=$true;LeafNonReparse=$true;SignatureValid=$true;Version=$policy.Version;X64=$true;PathIsolated=$true}
if ((Get-Phase12BSystemPythonState -Observation $exact).Classification -ne 'EXACT') { throw 'Exact Python observation was rejected.' }
foreach ($name in @('DirectoryIsContainer','DirectoryNonReparse','LeafPresent','LeafNonReparse','SignatureValid','X64','PathIsolated')) {
    $bad = $exact | ConvertTo-Json | ConvertFrom-Json
    $bad.$name = $false
    if ((Get-Phase12BSystemPythonState -Observation $bad).Classification -ne 'CONFLICT') { throw "Unsafe Python observation $name was accepted." }
}
$bad = $exact | ConvertTo-Json | ConvertFrom-Json; $bad.Version='3.13.14'
if ((Get-Phase12BSystemPythonState -Observation $bad).Classification -ne 'CONFLICT') { throw 'Wrong Python version was accepted.' }
$bad = $exact | ConvertTo-Json | ConvertFrom-Json; $bad.PathIsolated='true'
if ((Get-Phase12BSystemPythonState -Observation $bad).Classification -ne 'CONFLICT') { throw 'Malformed Boolean bypassed Python policy.' }
$bad = $exact | ConvertTo-Json | ConvertFrom-Json; $bad | Add-Member -NotePropertyName Extra -NotePropertyValue 1
if ((Get-Phase12BSystemPythonState -Observation $bad).Classification -ne 'CONFLICT') { throw 'Unknown Python observation field was accepted.' }
$missing = [pscustomobject]@{DirectoryPresent=$false;DirectoryIsContainer=$false;DirectoryNonReparse=$true;LeafPresent=$false;LeafNonReparse=$true;SignatureValid=$false;Version='';X64=$false;PathIsolated=$true}
if ((Get-Phase12BSystemPythonState -Observation $missing).Classification -ne 'MISSING') { throw 'Missing Python observation was not classified safely.' }
$script:current = $missing; $script:installs = 0
$read = { Get-Phase12BSystemPythonState -Observation $script:current }
$install = { $script:current = $exact; $script:installs++ }
if ((Invoke-Phase12BSystemPythonBootstrap -Read $read -Install $install) -ne 'INSTALLED' -or $script:installs -ne 1) { throw 'Python bootstrap did not install exact dependency.' }
if ((Invoke-Phase12BSystemPythonBootstrap -Read $read -Install $install) -ne 'ALREADY_EXACT' -or $script:installs -ne 1) { throw 'Python bootstrap duplicated installation.' }
$script:current = $missing; $script:current.PathIsolated=$false
Assert-Throws { Invoke-Phase12BSystemPythonBootstrap -Read $read -Install $install } 'Python bootstrap accepted path conflict.'

function New-LifecycleState {
    [pscustomobject]@{IdentityExact=$true;ServiceExact=$true;WorkflowExact=$true;UnknownState=$false;DispatchState='active';Quiescent=$true;PackageVerified=$false;RuntimeClassification='MISSING';PathIsolation='ISOLATED';ServiceState='Running';RunnerOnlineIdle=$true}
}
function Invoke-PythonFixture([string]$Start,[string]$Initial='active') {
    Invoke-Phase12BSystemRuntimeLifecycle -RuntimeKind Python313 -InitialStage $Start -InitialDispatchState $Initial -Read { $script:state } -Save { param($stage) $script:stage=$stage } -Mutate {
        param($action)
        $script:actions += @($action)
        if ($action -ceq $script:failAction) { throw "Injected provider failure: $action" }
        switch ($action) {
            'FenceDispatch' { $script:state.DispatchState='disabled_manually' }
            'VerifyPackage' { $script:state.PackageVerified=$true }
            'InstallRuntime' { $script:state.RuntimeClassification='EXACT' }
            'StopService' { $script:state.ServiceState='Stopped';$script:state.RunnerOnlineIdle=$false }
            'StartService' { $script:state.ServiceState='Running';$script:state.RunnerOnlineIdle=$true }
            'RestoreDispatch' { $script:state.DispatchState='active' }
        }
    }
}
$script:state=New-LifecycleState;$script:actions=@();$script:stage='PLANNED';$script:failAction=''
if ((Invoke-PythonFixture 'PLANNED') -ne 'COMPLETE') { throw 'Python lifecycle did not complete.' }
foreach ($action in @('FenceDispatch','VerifyPackage','InstallRuntime','StopService','StartService','RestoreDispatch')) { if ($action -notin $script:actions) { throw "Python lifecycle skipped $action." } }
foreach ($start in @('FENCING','INSTALLING','SERVICE_STOPPING','SERVICE_STARTING','DISPATCH_RESTORING')) {
    $script:state=New-LifecycleState;$script:state.DispatchState='disabled_manually';$script:state.PackageVerified=$true;$script:state.RuntimeClassification='EXACT';$script:state.ServiceState='Running';$script:state.RunnerOnlineIdle=$true
    if ($start -eq 'SERVICE_STOPPING') { $script:state.ServiceState='Stopped';$script:state.RunnerOnlineIdle=$false }
    if ($start -eq 'DISPATCH_RESTORING') { $script:state.DispatchState='active' }
    $script:actions=@();$script:stage=$start
    Invoke-PythonFixture $start | Out-Null
    $duplicate = switch ($start) { 'FENCING' {'FenceDispatch'} 'INSTALLING' {'InstallRuntime'} 'SERVICE_STOPPING' {'StopService'} 'SERVICE_STARTING' {'StartService'} 'DISPATCH_RESTORING' {'RestoreDispatch'} }
    if ($duplicate -in $script:actions -or $script:stage -ne 'COMPLETE') { throw "Python crash window $start duplicated a mutation." }
}
foreach ($failure in @('FenceDispatch','VerifyPackage','InstallRuntime','StopService','StartService','RestoreDispatch')) {
    $script:state=New-LifecycleState;$script:actions=@();$script:stage='PLANNED';$script:failAction=$failure
    Assert-Throws { Invoke-PythonFixture 'PLANNED' } "Provider failure $failure did not stop lifecycle."
    if ($script:stage -eq 'COMPLETE') { throw "Provider failure $failure persisted completion." }
}
$script:failAction='';$script:state=New-LifecycleState;$script:state.PathIsolation='CONFLICT'
Assert-Throws { Invoke-PythonFixture 'PLANNED' } 'PATH conflict was accepted on resume.'
$applySource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'apply-system-python.ps1') -Raw -ErrorAction Stop
if(@([regex]::Matches($applySource,"if \(\`$runtime\.Classification -eq 'CONFLICT'\) \{ throw 'System Python runtime classification is conflicted before resume mutation\.' \}")).Count -ne 2 -or
   @([regex]::Matches($applySource,"UnknownState=\([^\r\n]*\`$runtime\.Classification -eq 'CONFLICT'")).Count -ne 2){
    throw 'Test and Production Python read providers must both reject conflicted runtime before resume mutation.'
}
$script:state=New-LifecycleState;$script:state.RuntimeClassification='CONFLICT';$script:state.UnknownState=$true
$script:actions=@();$script:stage='PLANNED'
Assert-Throws { Invoke-PythonFixture 'PLANNED' } 'Partial/wrong Python runtime was allowed to resume.'
if($script:actions.Count -ne 0 -or $script:stage -ne 'PLANNED'){throw 'Conflicted Python runtime fenced dispatch or persisted a mutation stage.'}
'SYSTEM_PYTHON_TEST=PASS'
