Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Product-wide runtime policy. Machine-specific paths and caller identity remain in
# private desired state; this is the one supported Python distribution for the host.
$script:PythonPolicy = [pscustomobject]@{
    Version = '3.13.15'
    Asset = 'python-3.13.15-amd64.exe'
    Sha256 = 'edec09c4853aeae9ac36efb8c9f95b6b8e2fee65eee56d9767a8b7c69c574403'
    DownloadUrl = 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe'
}

function Get-Phase12BSystemPythonPolicy {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'System Python requires an x64 host process.' }
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if (-not [IO.Path]::IsPathRooted($programFiles)) { throw 'Program Files is unavailable.' }
    if (-not (Test-Path -LiteralPath $programFiles -PathType Container) -or
        ((Get-Item -LiteralPath $programFiles -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Program Files root is unsafe.' }
    $directory = Join-Path $programFiles 'Python313'
    [pscustomobject]@{
        Version = $script:PythonPolicy.Version
        Asset = $script:PythonPolicy.Asset
        Sha256 = $script:PythonPolicy.Sha256
        DownloadUrl = $script:PythonPolicy.DownloadUrl
        Directory = $directory
        Executable = Join-Path $directory 'python.exe'
    }
}

function Test-Phase12BPythonSignature {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or -not (Test-Phase12BNoReparse $Path)) { return $false }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    return [string]$signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        [string]$signature.SignerCertificate.Subject -match '(?:^|,\s*)CN=Python Software Foundation(?:,|$)' -and
        [string]$signature.SignerCertificate.Subject -match '(?:^|,\s*)O=Python Software Foundation(?:,|$)'
}

function Test-Phase12BPythonPathIsolation {
    param([Parameter(Mandatory)]$Policy)
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $machinePathExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'Machine')
    if ([string]::IsNullOrWhiteSpace($machinePath) -or [string]::IsNullOrWhiteSpace($machinePathExt)) { return $false }
    foreach ($part in ($machinePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($part)
        if (-not [IO.Path]::IsPathRooted($expanded)) { return $false }
        $directory = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
        if ($directory -ieq $Policy.Directory -or $directory -ieq (Join-Path $Policy.Directory 'Scripts')) { return $false }
    }
    return $true
}

function Get-Phase12BSystemPythonClassification {
    param([Parameter(Mandatory)]$Observation)
    $required = @('DirectoryPresent','DirectoryIsContainer','DirectoryNonReparse','LeafPresent','LeafNonReparse','SignatureValid','Version','X64','PathIsolated')
    foreach ($name in $required) { if (-not $Observation.PSObject.Properties[$name]) { return 'CONFLICT' } }
    if (@(Compare-Object ($required | Sort-Object) @($Observation.PSObject.Properties.Name | Sort-Object)).Count -ne 0) { return 'CONFLICT' }
    foreach ($name in @('DirectoryPresent','DirectoryIsContainer','DirectoryNonReparse','LeafPresent','LeafNonReparse','SignatureValid','X64','PathIsolated')) {
        if ($Observation.$name -isnot [bool]) { return 'CONFLICT' }
    }
    if ($Observation.Version -isnot [string] -or -not $Observation.PathIsolated) { return 'CONFLICT' }
    if (-not $Observation.DirectoryPresent) {
        if ($Observation.LeafPresent) { return 'CONFLICT' }
        return 'MISSING'
    }
    $policy = Get-Phase12BSystemPythonPolicy
    if ($Observation.DirectoryIsContainer -and $Observation.DirectoryNonReparse -and $Observation.LeafPresent -and
        $Observation.LeafNonReparse -and $Observation.SignatureValid -and $Observation.X64 -and
        [string]$Observation.Version -ceq $policy.Version) { return 'EXACT' }
    'CONFLICT'
}

function Get-Phase12BSystemPythonState {
    param($Observation)
    $policy = Get-Phase12BSystemPythonPolicy
    if ($null -eq $Observation) {
        $directoryPresent = Test-Path -LiteralPath $policy.Directory
        $leafPresent = Test-Path -LiteralPath $policy.Executable
        $safe = $directoryPresent -and (Test-Path -LiteralPath $policy.Directory -PathType Container) -and
            (Test-Phase12BNoReparse $policy.Directory) -and (Test-Path -LiteralPath $policy.Executable -PathType Leaf) -and
            (Test-Phase12BNoReparse $policy.Executable)
        $signatureValid = $false; $version = ''; $x64 = $false
        if ($safe) {
            $signatureValid = Test-Phase12BPythonSignature $policy.Executable
            if ($signatureValid) {
                try {
                    # Avoid embedded quotes: Windows PowerShell 5 native-argument
                    # marshalling strips them before Python receives -c.
                    $raw = & $policy.Executable -I -c 'import platform,sys;print(platform.python_version(),platform.architecture()[0],sys.executable,sep=chr(59))' 2>$null
                    if ($LASTEXITCODE -ne 0) { throw 'Python invocation failed.' }
                    $parts = ([string]($raw | Select-Object -Last 1)) -split ';'
                    if ($parts.Count -eq 3 -and [string]$parts[2] -ieq [string]$policy.Executable) {
                        $version = [string]$parts[0]; $x64 = [string]$parts[1] -ceq '64bit'
                    }
                } catch { $version = ''; $x64 = $false }
            }
        }
        $Observation = [pscustomobject]@{
            DirectoryPresent=$directoryPresent;DirectoryIsContainer=(Test-Path -LiteralPath $policy.Directory -PathType Container)
            DirectoryNonReparse=if($directoryPresent){Test-Phase12BNoReparse $policy.Directory}else{$true}
            LeafPresent=$leafPresent;LeafNonReparse=if($leafPresent){Test-Phase12BNoReparse $policy.Executable}else{$true}
            SignatureValid=$signatureValid;Version=$version;X64=$x64;PathIsolated=(Test-Phase12BPythonPathIsolation $policy)
        }
    }
    [pscustomobject]@{Classification=(Get-Phase12BSystemPythonClassification $Observation);Path=$policy.Executable;Version=[string]$Observation.Version;PathIsolated=[bool]$Observation.PathIsolated}
}

function Get-Phase12BVerifiedSystemPythonPackage {
    param([Parameter(Mandatory)][string]$CacheRoot)
    $policy = Get-Phase12BSystemPythonPolicy
    if (-not (Test-Path -LiteralPath $CacheRoot -PathType Container) -or -not (Test-Phase12BNoReparse $CacheRoot) -or
        -not (Test-Phase12BAclPolicy -Acl (Get-Acl -LiteralPath $CacheRoot))) { throw 'Python package cache root is unsafe.' }
    $cache = Join-Path $CacheRoot 'packages'
    if (-not (Test-Path -LiteralPath $cache)) {
        New-Item -ItemType Directory -Path $cache -ErrorAction Stop | Out-Null
        Invoke-Phase12BAction -Name ApplyAcl -Argument $cache
    }
    if (-not (Test-Path -LiteralPath $cache -PathType Container) -or -not (Test-Phase12BNoReparse $cache) -or
        -not (Test-Phase12BAclPolicy -Acl (Get-Acl -LiteralPath $cache))) { throw 'Python package cache is unsafe.' }
    $unknown = @(Get-ChildItem -LiteralPath $cache -Force -ErrorAction Stop | Where-Object { $_.Name -cne $policy.Asset })
    if ($unknown.Count -ne 0) { throw 'Python package cache contains unknown or interrupted content.' }
    $package = Join-Path $cache $policy.Asset
    if (-not (Test-Path -LiteralPath $package)) {
        $temporary = Join-Path $cache ('.downloading-' + $policy.Asset)
        if (Test-Path -LiteralPath $temporary) { throw 'Python download residue requires explicit recovery.' }
        Invoke-WebRequest -Uri $policy.DownloadUrl -OutFile $temporary -ErrorAction Stop
        if ([string](Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $policy.Sha256 -or
            -not (Test-Phase12BPythonSignature $temporary)) { throw 'Python installer digest or publisher mismatch.' }
        Move-Item -LiteralPath $temporary -Destination $package -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $package -PathType Leaf) -or -not (Test-Phase12BNoReparse $package) -or
        [string](Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ine $policy.Sha256 -or
        -not (Test-Phase12BPythonSignature $package)) { throw 'Python installer digest or publisher mismatch.' }
    $package
}

function Install-Phase12BSystemPython {
    param([Parameter(Mandatory)][string]$CacheRoot)
    $before = Get-Phase12BSystemPythonState
    if ($before.Classification -eq 'EXACT') { return $before }
    if ($before.Classification -ne 'MISSING') { throw 'Existing system Python is contradictory.' }
    $policy = Get-Phase12BSystemPythonPolicy
    $pathBefore = [Environment]::GetEnvironmentVariable('Path','Machine')
    $pathExtBefore = [Environment]::GetEnvironmentVariable('PATHEXT','Machine')
    $package = Get-Phase12BVerifiedSystemPythonPackage -CacheRoot $CacheRoot
    # No PATH/launcher/association or optional download components. The core
    # interpreter, standard library and development component remain enabled.
    $arguments = @('/quiet','InstallAllUsers=1',("TargetDir=`"$($policy.Directory)`""),'PrependPath=0','AppendPath=0',
        'Include_launcher=0','Include_pip=0','Include_doc=0','Include_tcltk=0','Include_test=0','Include_tools=0',
        'Include_exe=1','Include_lib=1','Include_dev=1','Include_symbols=0','Include_debug=0',
        'Include_freethreaded=0','AssociateFiles=0','Shortcuts=0','SimpleInstall=0')
    if ([string][Environment]::GetEnvironmentVariable('Path','Machine') -cne [string]$pathBefore -or
        [string][Environment]::GetEnvironmentVariable('PATHEXT','Machine') -cne [string]$pathExtBefore) { throw 'Machine PATH or PATHEXT changed before Python installation.' }
    $process = Start-Process -FilePath $package -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    if ($process.ExitCode -eq 3010) { throw 'Python installation requires reboot; stop before Service restart.' }
    if ($process.ExitCode -ne 0) { throw "Python installation failed with exit code $($process.ExitCode)." }
    if ([string][Environment]::GetEnvironmentVariable('Path','Machine') -cne [string]$pathBefore -or
        [string][Environment]::GetEnvironmentVariable('PATHEXT','Machine') -cne [string]$pathExtBefore) { throw 'Python installation unexpectedly changed machine PATH or PATHEXT.' }
    $after = Get-Phase12BSystemPythonState
    if ($after.Classification -ne 'EXACT') { throw 'Python installation read-back did not reach exact policy.' }
    $after
}

function Invoke-Phase12BSystemPythonBootstrap {
    param([Parameter(Mandatory)][scriptblock]$Read,[Parameter(Mandatory)][scriptblock]$Install)
    $before = & $Read
    if ($before.Classification -eq 'EXACT' -and $before.PathIsolated) { return 'ALREADY_EXACT' }
    if ($before.Classification -ne 'MISSING' -or -not $before.PathIsolated) { throw 'Bootstrap Python dependency is contradictory.' }
    & $Install
    $after = & $Read
    if ($after.Classification -ne 'EXACT' -or -not $after.PathIsolated) { throw 'Bootstrap Python dependency read-back failed.' }
    'INSTALLED'
}

Export-ModuleMember -Function Get-Phase12BSystemPythonPolicy,Test-Phase12BPythonSignature,Test-Phase12BPythonPathIsolation,Get-Phase12BSystemPythonClassification,Get-Phase12BSystemPythonState,Get-Phase12BVerifiedSystemPythonPackage,Install-Phase12BSystemPython,Invoke-Phase12BSystemPythonBootstrap
