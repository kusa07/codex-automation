Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Product-wide policy, not machine-specific desired state. Never use "latest".
$script:PowerShellRuntimePolicy = [pscustomobject]@{
    Version = '7.6.6'
    Asset = 'PowerShell-7.6.6-win-x64.msi'
    Sha256 = '958838ff55091e1c8705d89efed0cc7e8245a3a6ef6c0ccfae20015227108ad8'
    ReleaseApi = 'repos/PowerShell/PowerShell/releases/tags/v7.6.6'
    DownloadUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi'
}

function Get-Phase12BSystemRuntimePolicy {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'Phase 12B system PowerShell runtime requires a 64-bit host process.' }
    $root = [Environment]::GetFolderPath('ProgramFiles')
    if (-not [IO.Path]::IsPathRooted($root)) { throw 'Program Files path is unavailable.' }
    [pscustomobject]@{
        Version = $script:PowerShellRuntimePolicy.Version
        Asset = $script:PowerShellRuntimePolicy.Asset
        Sha256 = $script:PowerShellRuntimePolicy.Sha256
        ReleaseApi = $script:PowerShellRuntimePolicy.ReleaseApi
        DownloadUrl = $script:PowerShellRuntimePolicy.DownloadUrl
        Directory = Join-Path $root 'PowerShell\7'
        Executable = Join-Path $root 'PowerShell\7\pwsh.exe'
    }
}

function Test-Phase12BMicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    return [string]$sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate -and
        [string]$sig.SignerCertificate.Subject -match '(?:^|,\s*)CN=Microsoft Corporation(?:,|$)' -and
        [string]$sig.SignerCertificate.Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'
}

function Test-Phase12BPowerShellReleaseAsset {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)]$Policy)
    if ([string]$Release.tag_name -cne ('v' + $Policy.Version) -or [bool]$Release.draft -or [bool]$Release.prerelease) { return $false }
    $assets = @($Release.assets | Where-Object { [string]$_.name -ceq $Policy.Asset })
    if ($assets.Count -ne 1) { return $false }
    $asset = $assets[0]
    return [string]$asset.browser_download_url -ceq [string]$Policy.DownloadUrl -and
        [string]$asset.digest -ceq ('sha256:' + [string]$Policy.Sha256) -and
        [int64]$asset.size -gt 0
}

function Get-Phase12BMachinePwshPathState {
    param([Parameter(Mandatory)][string]$ExpectedDirectory)
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ([string]::IsNullOrWhiteSpace($machinePath)) { return 'MISSING' }
    $expected = [IO.Path]::GetFullPath($ExpectedDirectory).TrimEnd('\')
    $seen = $false
    foreach ($part in ($machinePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($part)
        if (-not [IO.Path]::IsPathRooted($expanded)) { return 'CONFLICT' }
        $directory = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
        if ($directory -ieq $expected) {
            if ($seen) { return 'CONFLICT' }
            $seen = $true
            continue
        }
        if (-not $seen -and (Test-Path -LiteralPath (Join-Path $directory 'pwsh.exe'))) { return 'SHADOWED' }
    }
    if ($seen) { return 'EXACT' }
    return 'MISSING'
}

function Get-Phase12BSystemRuntimeClassification {
    param([Parameter(Mandatory)]$Observation)
    $required = @('DirectoryPresent','DirectoryIsContainer','DirectoryNonReparse','LeafPresent','LeafNonReparse','SignatureValid','Version','X64','MachinePath')
    foreach ($name in $required) { if (-not $Observation.PSObject.Properties[$name]) { return 'CONFLICT' } }
    if (@(Compare-Object ($required | Sort-Object) @($Observation.PSObject.Properties.Name | Sort-Object)).Count -ne 0) { return 'CONFLICT' }
    foreach ($name in @('DirectoryPresent','DirectoryIsContainer','DirectoryNonReparse','LeafPresent','LeafNonReparse','SignatureValid','X64')) { if ($Observation.$name -isnot [bool]) { return 'CONFLICT' } }
    if ($Observation.Version -isnot [string] -or $Observation.MachinePath -isnot [string]) { return 'CONFLICT' }
    if ([string]$Observation.MachinePath -notin @('EXACT','MISSING','SHADOWED','CONFLICT')) { return 'CONFLICT' }
    if (-not [bool]$Observation.DirectoryPresent) {
        if ([bool]$Observation.LeafPresent) { return 'CONFLICT' }
        return 'MISSING'
    }
    $policy = Get-Phase12BSystemRuntimePolicy
    if ([bool]$Observation.DirectoryIsContainer -and [bool]$Observation.DirectoryNonReparse -and
        [bool]$Observation.LeafPresent -and [bool]$Observation.LeafNonReparse -and [bool]$Observation.SignatureValid -and
        [string]$Observation.Version -ceq $policy.Version -and [bool]$Observation.X64 -and
        [string]$Observation.MachinePath -eq 'EXACT') { return 'EXACT' }
    'CONFLICT'
}

function Get-Phase12BSystemRuntimeState {
    param($Observation)
    $policy = Get-Phase12BSystemRuntimePolicy
    if ($null -eq $Observation) {
        $directoryPresent = Test-Path -LiteralPath $policy.Directory
        $leafPresent = Test-Path -LiteralPath $policy.Executable
        $safe = $directoryPresent -and (Test-Path -LiteralPath $policy.Directory -PathType Container) -and
            (Test-Phase12BNoReparse $policy.Directory) -and (Test-Path -LiteralPath $policy.Executable -PathType Leaf) -and
            (Test-Phase12BNoReparse $policy.Executable)
        $signatureValid = $false; $version = ''; $x64 = $false
        if ($safe) {
            $signatureValid = Test-Phase12BMicrosoftSignature -Path $policy.Executable
            if ($signatureValid) {
                try {
                    $raw = & $policy.Executable -NoLogo -NoProfile -NonInteractive -Command '[string]$PSVersionTable.PSVersion.ToString() + [char]59 + [string][Environment]::Is64BitProcess' 2>$null
                    if ($LASTEXITCODE -ne 0) { throw 'pwsh failed' }
                    $parts = ([string]($raw | Select-Object -Last 1)) -split ';'
                    if ($parts.Count -eq 2) { $version = $parts[0]; $x64 = $parts[1] -ceq 'True' }
                } catch { $version = ''; $x64 = $false }
            }
        }
        $Observation = [pscustomobject]@{
            DirectoryPresent=$directoryPresent;DirectoryIsContainer=(Test-Path -LiteralPath $policy.Directory -PathType Container)
            DirectoryNonReparse=if($directoryPresent){Test-Phase12BNoReparse $policy.Directory}else{$true}
            LeafPresent=$leafPresent;LeafNonReparse=if($leafPresent){Test-Phase12BNoReparse $policy.Executable}else{$true}
            SignatureValid=$signatureValid;Version=$version;X64=$x64
            MachinePath=(Get-Phase12BMachinePwshPathState -ExpectedDirectory $policy.Directory)
        }
    }
    [pscustomobject]@{ Classification=(Get-Phase12BSystemRuntimeClassification -Observation $Observation);Path=$policy.Executable;Version=[string]$Observation.Version;MachinePath=[string]$Observation.MachinePath }
}

function Get-Phase12BVerifiedSystemRuntimePackage {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container) -or -not (Test-Phase12BNoReparse $RuntimeRoot)) { throw 'Managed runtime root is unsafe.' }
    $policy = Get-Phase12BSystemRuntimePolicy
    $raw = & gh api $policy.ReleaseApi 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Official PowerShell release read-back failed.' }
    try { $release = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Official PowerShell release response is malformed.' }
    if (-not (Test-Phase12BPowerShellReleaseAsset -Release $release -Policy $policy)) { throw 'Official PowerShell release provenance mismatch.' }
    $packages = Join-Path $RuntimeRoot 'packages'
    if (-not (Test-Path -LiteralPath $packages)) {
        New-Item -ItemType Directory -Path $packages -ErrorAction Stop | Out-Null
        Invoke-Phase12BAction -Name ApplyAcl -Argument $packages
    }
    if (-not (Test-Phase12BNoReparse $packages) -or -not (Test-Phase12BAclPolicy -Acl (Get-Acl -LiteralPath $packages))) { throw 'PowerShell package directory or ACL is unsafe.' }
    if (@(Get-ChildItem -LiteralPath $packages -Force -ErrorAction Stop | Where-Object { $_.Name -cne $policy.Asset }).Count -ne 0) { throw 'PowerShell package directory contains unknown or interrupted content.' }
    $msi = Join-Path $packages $policy.Asset
    if (-not (Test-Path -LiteralPath $msi)) {
        $temporary = Join-Path $packages ('.downloading-' + $policy.Asset)
        if (Test-Path -LiteralPath $temporary) { throw 'PowerShell package download residue requires explicit recovery.' }
        Invoke-WebRequest -Uri $policy.DownloadUrl -OutFile $temporary -ErrorAction Stop
        if ([string](Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $policy.Sha256 -or -not (Test-Phase12BMicrosoftSignature $temporary)) { throw 'PowerShell MSI digest or publisher is invalid.' }
        Move-Item -LiteralPath $temporary -Destination $msi -ErrorAction Stop
    }
    if (-not (Test-Phase12BNoReparse $msi) -or [string](Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ine $policy.Sha256 -or -not (Test-Phase12BMicrosoftSignature $msi)) { throw 'PowerShell MSI digest or publisher is invalid.' }
    $msi
}

function Install-Phase12BSystemRuntime {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $before = Get-Phase12BSystemRuntimeState
    if ($before.Classification -eq 'EXACT') { return $before }
    if ($before.Classification -ne 'MISSING' -or $before.MachinePath -ne 'MISSING') { throw 'Existing PowerShell runtime or machine PATH is contradictory.' }
    $policy = Get-Phase12BSystemRuntimePolicy
    $msi = Get-Phase12BVerifiedSystemRuntimePackage -RuntimeRoot $RuntimeRoot
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/i', ('"' + $msi + '"'), '/qn', '/norestart', 'ADD_PATH=1', 'USE_MU=0', 'ENABLE_MU=0') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    if ($process.ExitCode -eq 3010) { throw 'PowerShell MSI requires reboot; stop before Service restart.' }
    if ($process.ExitCode -ne 0) { throw "PowerShell MSI failed with exit code $($process.ExitCode)." }
    $after = Get-Phase12BSystemRuntimeState
    if ($after.Classification -ne 'EXACT') { throw 'PowerShell installation read-back did not reach exact policy.' }
    $after
}

function Get-Phase12BSystemRuntimeDecision {
    param([Parameter(Mandatory)]$State)
    if ($State.HostState -ne 'EXISTING' -or -not $State.CallerExact -or -not $State.ServiceExact -or
        -not $State.RepositoryIdentityExact -or -not $State.WorkflowExact -or -not $State.RunnerIdentityExact -or
        $State.RuntimeClassification -eq 'CONFLICT' -or $State.DispatchState -notin @('active','disabled_manually')) {
        return 'CONFLICT'
    }
    if ($State.RuntimeClassification -eq 'EXACT' -and $State.MachinePath -eq 'EXACT' -and $State.ServiceState -eq 'Running' -and $State.RunnerOnlineIdle) { return 'REFRESH_REQUIRED' }
    if ($State.RuntimeClassification -eq 'MISSING' -and $State.MachinePath -eq 'MISSING' -and $State.ServiceState -eq 'Running' -and $State.RunnerOnlineIdle) { return 'INSTALLABLE' }
    return 'CONFLICT'
}

function Invoke-Phase12BSystemRuntimeBootstrap {
    param([Parameter(Mandatory)][scriptblock]$Read,[Parameter(Mandatory)][scriptblock]$Install)
    $before = & $Read
    if ($before.Classification -eq 'EXACT') { return 'ALREADY_EXACT' }
    if ($before.Classification -ne 'MISSING' -or $before.MachinePath -ne 'MISSING') { throw 'Bootstrap PowerShell dependency is contradictory.' }
    & $Install
    $after = & $Read
    if ($after.Classification -ne 'EXACT' -or $after.MachinePath -ne 'EXACT') { throw 'Bootstrap PowerShell dependency read-back failed.' }
    'INSTALLED'
}

# The lifecycle is shared by TestMode and Production. Providers only read or
# mutate external state; they do not decide the next migration stage.
function Invoke-Phase12BSystemRuntimeLifecycle {
    param([Parameter(Mandatory)][string]$InitialStage,
          [Parameter(Mandatory)][string]$InitialDispatchState,
          [Parameter(Mandatory)][scriptblock]$Read,
          [Parameter(Mandatory)][scriptblock]$Mutate,
          [Parameter(Mandatory)][scriptblock]$Save,
          [ValidateSet('PowerShell7','Python313')][string]$RuntimeKind = 'PowerShell7')
    $stages = @('PLANNED','FENCING','FENCED','QUIESCENCE_CHECKING','QUIESCENT','PACKAGE_VERIFYING','PACKAGE_VERIFIED','INSTALLING','INSTALLED','PATH_VERIFIED','SERVICE_STOPPING','SERVICE_STOPPED','SERVICE_STARTING','SERVICE_STARTED','RUNTIME_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','COMPLETE')
    if ($InitialStage -notin $stages -or $InitialDispatchState -notin @('active','disabled_manually')) { throw 'Runtime lifecycle intent is invalid.' }
    $stage = $InitialStage
    function State { & $Read }
    function Advance([string]$Next) { & $Save $Next; Set-Variable -Name stage -Value $Next -Scope 1 }
    $actual = State
    if (-not $actual.IdentityExact -or -not $actual.ServiceExact -or -not $actual.WorkflowExact -or $actual.UnknownState) { throw 'Runtime dependency authority changed or is unknown.' }
    if ($stage -eq 'COMPLETE') {
        if ($actual.RuntimeClassification -ne 'EXACT' -or $actual.ServiceState -ne 'Running' -or -not $actual.RunnerOnlineIdle -or $actual.DispatchState -cne $InitialDispatchState -or
            ($RuntimeKind -eq 'Python313' -and $actual.PathIsolation -ne 'ISOLATED')) { throw 'Completed runtime postcondition is not exact.' }
        return 'COMPLETE'
    }
    if ($stage -eq 'PLANNED') { Advance 'FENCING' }
    if ($stage -eq 'FENCING') {
        $actual = State
        if ($actual.DispatchState -notin @('active','disabled_manually')) { throw 'Dispatch state is ambiguous.' }
        if ($actual.DispatchState -eq 'active') { & $Mutate 'FenceDispatch' }
        $actual = State
        if ($actual.DispatchState -ne 'disabled_manually') { throw 'Dispatch fence read-back failed.' }
        Advance 'FENCED'
    }
    if ($stage -eq 'FENCED') { Advance 'QUIESCENCE_CHECKING' }
    if ($stage -eq 'QUIESCENCE_CHECKING') {
        $actual = State
        if ($actual.DispatchState -ne 'disabled_manually') { throw 'Dispatch fence was lost.' }
        if (-not $actual.Quiescent) { & $Mutate 'WaitForQuiescence' }
        $actual = State
        if (-not $actual.Quiescent) { throw 'Runtime change requires quiescence.' }
        Advance 'QUIESCENT'
    }
    if ($stage -eq 'QUIESCENT') { Advance 'PACKAGE_VERIFYING' }
    if ($stage -eq 'PACKAGE_VERIFYING') {
        $actual = State
        if ($actual.DispatchState -ne 'disabled_manually' -or -not $actual.Quiescent) { throw 'Package verification requires fenced quiescence.' }
        if ($actual.RuntimeClassification -ne 'EXACT') {
            & $Mutate 'VerifyPackage'
            $actual = State
            if (-not $actual.PackageVerified) { throw 'PowerShell package read-back failed.' }
        }
        Advance 'PACKAGE_VERIFIED'
    }
    if ($stage -eq 'PACKAGE_VERIFIED') { Advance 'INSTALLING' }
    if ($stage -eq 'INSTALLING') {
        $actual = State
        if ($actual.DispatchState -ne 'disabled_manually' -or -not $actual.Quiescent -or ($actual.RuntimeClassification -eq 'MISSING' -and -not $actual.PackageVerified)) { throw 'PowerShell installation preconditions changed.' }
        if ($actual.RuntimeClassification -eq 'MISSING') { & $Mutate 'InstallRuntime' }
        $actual = State
        if ($actual.RuntimeClassification -ne 'EXACT') { throw 'PowerShell installation read-back failed.' }
        Advance 'INSTALLED'
    }
    if ($stage -eq 'INSTALLED') {
        $actual = State
        if ($actual.RuntimeClassification -ne 'EXACT') { throw 'System runtime is not exact.' }
        if ($RuntimeKind -eq 'PowerShell7' -and $actual.MachinePath -ne 'EXACT') { throw 'Machine PATH is not exact.' }
        if ($RuntimeKind -eq 'Python313' -and $actual.PathIsolation -ne 'ISOLATED') { throw 'Python PATH isolation is not exact.' }
        Advance 'PATH_VERIFIED'
    }
    if ($stage -eq 'PATH_VERIFIED') { Advance 'SERVICE_STOPPING' }
    if ($stage -eq 'SERVICE_STOPPING') {
        $actual = State
        if ($actual.DispatchState -ne 'disabled_manually' -or -not $actual.Quiescent -or -not $actual.ServiceExact -or $actual.ServiceState -notin @('Running','Stopped')) { throw 'Service stop preconditions changed.' }
        if ($actual.ServiceState -eq 'Running') { & $Mutate 'StopService' }
        $actual = State
        if ($actual.ServiceState -ne 'Stopped') { throw 'Exact Service stop read-back failed.' }
        Advance 'SERVICE_STOPPED'
    }
    if ($stage -eq 'SERVICE_STOPPED') { Advance 'SERVICE_STARTING' }
    if ($stage -eq 'SERVICE_STARTING') {
        $actual = State
        if ($actual.DispatchState -ne 'disabled_manually' -or -not $actual.ServiceExact -or $actual.ServiceState -notin @('Running','Stopped')) { throw 'Service start preconditions changed.' }
        if ($actual.ServiceState -eq 'Stopped') { & $Mutate 'StartService' }
        $actual = State
        if ($actual.ServiceState -ne 'Running' -or -not $actual.ServiceExact) { throw 'Exact Service Running read-back failed.' }
        Advance 'SERVICE_STARTED'
    }
    if ($stage -eq 'SERVICE_STARTED') {
        $actual = State
        if ($actual.ServiceState -eq 'Running' -and -not $actual.RunnerOnlineIdle) { & $Mutate 'WaitForRunnerOnline'; $actual = State }
        if ($actual.RuntimeClassification -ne 'EXACT' -or $actual.ServiceState -ne 'Running' -or -not $actual.RunnerOnlineIdle -or -not $actual.IdentityExact) { throw 'Runner/Service post-restart read-back failed.' }
        Advance 'RUNTIME_VERIFIED'
    }
    if ($stage -eq 'RUNTIME_VERIFIED') { Advance 'DISPATCH_RESTORING' }
    if ($stage -eq 'DISPATCH_RESTORING') {
        $actual = State
        if ($actual.RuntimeClassification -ne 'EXACT' -or $actual.ServiceState -ne 'Running' -or -not $actual.RunnerOnlineIdle) { throw 'Runtime postcondition was lost before dispatch restoration.' }
        if ($actual.DispatchState -ne $InitialDispatchState) {
            if ($InitialDispatchState -ne 'active' -or $actual.DispatchState -ne 'disabled_manually') { throw 'Dispatch state is ambiguous.' }
            & $Mutate 'RestoreDispatch'
        }
        $actual = State
        if ($actual.DispatchState -cne $InitialDispatchState) { throw 'Dispatch restoration read-back failed.' }
        Advance 'DISPATCH_RESTORED'
    }
    if ($stage -eq 'DISPATCH_RESTORED') {
        $actual = State
        if ($actual.RuntimeClassification -ne 'EXACT' -or $actual.ServiceState -ne 'Running' -or -not $actual.RunnerOnlineIdle -or $actual.DispatchState -cne $InitialDispatchState -or -not $actual.IdentityExact) { throw 'Runtime final verification failed.' }
        Advance 'COMPLETE'
    }
    'COMPLETE'
}

Export-ModuleMember -Function Get-Phase12BSystemRuntimePolicy,Test-Phase12BMicrosoftSignature,Test-Phase12BPowerShellReleaseAsset,Get-Phase12BMachinePwshPathState,Get-Phase12BSystemRuntimeClassification,Get-Phase12BSystemRuntimeState,Get-Phase12BVerifiedSystemRuntimePackage,Install-Phase12BSystemRuntime,Get-Phase12BSystemRuntimeDecision,Invoke-Phase12BSystemRuntimeBootstrap,Invoke-Phase12BSystemRuntimeLifecycle
