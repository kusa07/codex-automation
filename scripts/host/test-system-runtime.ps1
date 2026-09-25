$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'phase12b-system-runtime.psm1') -Force
function Assert-Throws([scriptblock]$Call, [string]$Message) { try { & $Call } catch { return }; throw $Message }
$policy = Get-Phase12BSystemRuntimePolicy
$exactObservation=[pscustomobject]@{DirectoryPresent=$true;DirectoryIsContainer=$true;DirectoryNonReparse=$true;LeafPresent=$true;LeafNonReparse=$true;SignatureValid=$true;Version=$policy.Version;X64=$true;MachinePath='EXACT'}
if((Get-Phase12BSystemRuntimeState -Observation $exactObservation).Classification -ne 'EXACT'){throw 'Structured exact runtime observation was rejected.'}
foreach($badField in @('DirectoryNonReparse','LeafNonReparse','SignatureValid','X64')){$bad=$exactObservation|ConvertTo-Json|ConvertFrom-Json;$bad.$badField=$false;if((Get-Phase12BSystemRuntimeState -Observation $bad).Classification -ne 'CONFLICT'){throw "Unsafe $badField runtime observation was accepted."}}
$bad=$exactObservation|ConvertTo-Json|ConvertFrom-Json;$bad.SignatureValid='false';if((Get-Phase12BSystemRuntimeState -Observation $bad).Classification -ne 'CONFLICT'){throw 'String boolean fixture bypassed runtime classification.'}
$bad=$exactObservation|ConvertTo-Json|ConvertFrom-Json;$bad.MachinePath='SHADOWED';if((Get-Phase12BSystemRuntimeState -Observation $bad).Classification -ne 'CONFLICT'){throw 'PATH shadowing was accepted.'}
$script:bootstrapClass='MISSING';$script:bootstrapPath='EXACT';$script:bootstrapInstalls=0
Assert-Throws { Invoke-Phase12BSystemRuntimeBootstrap -Read { [pscustomobject]@{Classification=$script:bootstrapClass;MachinePath=$script:bootstrapPath} } -Install { $script:bootstrapInstalls++ } } 'Stale exact PATH without installed pwsh was accepted.'
if($script:bootstrapInstalls -ne 0){throw 'Stale PATH triggered installation.'}
$goodRelease = [pscustomobject]@{tag_name='v7.6.6';draft=$false;prerelease=$false;assets=@([pscustomobject]@{name=$policy.Asset;digest=('sha256:'+$policy.Sha256);browser_download_url=$policy.DownloadUrl;size=1000})}
if (-not (Test-Phase12BPowerShellReleaseAsset -Release $goodRelease -Policy $policy)) { throw 'Official release fixture was rejected.' }
foreach ($change in @('tag','digest','url','preview','duplicate')) {
    $copy = $goodRelease | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    switch ($change) {
        'tag' { $copy.tag_name='v7.6.5' }
        'digest' { $copy.assets[0].digest='sha256:' + ('0'*64) }
        'url' { $copy.assets[0].browser_download_url='https://example.invalid/powershell.msi' }
        'preview' { $copy.prerelease=$true }
        'duplicate' { $copy.assets=@($copy.assets[0],$copy.assets[0]) }
    }
    if (Test-Phase12BPowerShellReleaseAsset -Release $copy -Policy $policy) { throw "Unsafe $change PowerShell release was accepted." }
}
$read = { [pscustomobject]@{Classification=$script:bootstrapClass;MachinePath=$script:bootstrapPath} }
$install = { $script:bootstrapClass='EXACT';$script:bootstrapPath='EXACT';$script:bootstrapInstalls++ }
$script:bootstrapClass='MISSING';$script:bootstrapPath='MISSING';$script:bootstrapInstalls=0
if ((Invoke-Phase12BSystemRuntimeBootstrap -Read $read -Install $install) -ne 'INSTALLED' -or $script:bootstrapInstalls -ne 1) { throw 'Bootstrap dependency install failed.' }
if ((Invoke-Phase12BSystemRuntimeBootstrap -Read $read -Install $install) -ne 'ALREADY_EXACT' -or $script:bootstrapInstalls -ne 1) { throw 'Bootstrap exact dependency was reinstalled.' }
$script:bootstrapClass='CONFLICT';Assert-Throws { Invoke-Phase12BSystemRuntimeBootstrap -Read $read -Install $install } 'Bootstrap accepted contradictory runtime.'

function New-State {
    [pscustomobject]@{IdentityExact=$true;ServiceExact=$true;WorkflowExact=$true;UnknownState=$false;DispatchState='active';Quiescent=$true;PackageVerified=$false;RuntimeClassification='MISSING';MachinePath='MISSING';ServiceState='Running';RunnerOnlineIdle=$true}
}
function Run-Fixture([string]$Start, [string]$Initial='active') {
    Invoke-Phase12BSystemRuntimeLifecycle -InitialStage $Start -InitialDispatchState $Initial -Read { $script:s } -Save { param($stage) $script:stage=$stage;$script:stages+=@($stage) } -Mutate {
        param($action)
        $script:actions+=@($action)
        if ($script:failAction -eq $action) { throw "Injected $action failure." }
        switch ($action) {
            'FenceDispatch' { $script:s.DispatchState='disabled_manually' }
            'VerifyPackage' { $script:s.PackageVerified=$true }
            'InstallRuntime' { $script:s.RuntimeClassification='EXACT';$script:s.MachinePath='EXACT' }
            'StopService' { $script:s.ServiceState='Stopped';$script:s.RunnerOnlineIdle=$false }
            'StartService' { $script:s.ServiceState='Running';$script:s.RunnerOnlineIdle=$true }
            'RestoreDispatch' { $script:s.DispatchState='active' }
        }
    }
}
$script:s=New-State;$script:stage='PLANNED';$script:stages=@();$script:actions=@();$script:failAction=''
if ((Run-Fixture 'PLANNED') -ne 'COMPLETE' -or $script:stage -ne 'COMPLETE') { throw 'Runtime lifecycle did not complete.' }
foreach ($expected in @('FenceDispatch','VerifyPackage','InstallRuntime','StopService','StartService','RestoreDispatch')) { if ($expected -notin $script:actions) { throw "Runtime lifecycle skipped $expected." } }
if ((Run-Fixture 'COMPLETE') -ne 'COMPLETE') { throw 'Completed runtime verification failed.' }

# A crash immediately after a successful external action must not duplicate it.
foreach ($case in @('FENCING','INSTALLING','SERVICE_STOPPING','SERVICE_STARTING','DISPATCH_RESTORING')) {
    $script:s=New-State;$script:s.DispatchState='disabled_manually';$script:s.PackageVerified=$true;$script:s.RuntimeClassification='EXACT';$script:s.MachinePath='EXACT';$script:s.ServiceState='Running';$script:s.RunnerOnlineIdle=$true
    if ($case -eq 'SERVICE_STOPPING') { $script:s.ServiceState='Stopped';$script:s.RunnerOnlineIdle=$false }
    if ($case -eq 'SERVICE_STARTING') { $script:s.ServiceState='Running' }
    if ($case -eq 'DISPATCH_RESTORING') { $script:s.DispatchState='active' }
    $script:actions=@();$script:stages=@();$script:stage=$case
    Run-Fixture $case | Out-Null
    $duplicate = switch ($case) { 'FENCING' {'FenceDispatch'} 'INSTALLING' {'InstallRuntime'} 'SERVICE_STOPPING' {'StopService'} 'SERVICE_STARTING' {'StartService'} 'DISPATCH_RESTORING' {'RestoreDispatch'} }
    if ($duplicate -in $script:actions -or $script:stage -ne 'COMPLETE') { throw "Crash window $case duplicated $duplicate or failed to complete." }
}
$script:s=New-State;$script:s.DispatchState='disabled_manually';$script:actions=@();$script:stages=@();$script:stage='PLANNED'
Run-Fixture 'PLANNED' 'disabled_manually' | Out-Null
if ('FenceDispatch' -in $script:actions -or 'RestoreDispatch' -in $script:actions -or $script:s.DispatchState -ne 'disabled_manually') { throw 'Preexisting disabled dispatch was changed.' }
foreach ($failure in @('FenceDispatch','VerifyPackage','InstallRuntime','StopService','StartService','RestoreDispatch')) {
    $script:s=New-State;$script:stage='PLANNED';$script:stages=@();$script:actions=@();$script:failAction=$failure
    Assert-Throws { Run-Fixture 'PLANNED' | Out-Null } "Injected $failure failure did not stop lifecycle."
    if ($script:stage -eq 'COMPLETE') { throw "Injected $failure failure persisted complete." }
}
$script:failAction='';$script:s=New-State;$script:s.UnknownState=$true
Assert-Throws { Run-Fixture 'PLANNED' | Out-Null } 'Unknown state was accepted.'
'SYSTEM_RUNTIME_TEST=PASS'
