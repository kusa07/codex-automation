$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'phase12b-host.psm1') -Force
foreach($version in @('version 4.53.6','version v4.53.6','yq version 4.53.6','yq (https://github.com/mikefarah/yq/) version v4.53.6')){if(-not(Test-Phase12BYqV4Version $version)){throw "valid yq v4 version was rejected: $version"}}
foreach($version in @('version v3.4.1','version 3.4.1','version v5.0.0','version 5.0.0','','unrelated tool 4 version output')){if(Test-Phase12BYqV4Version $version){throw "invalid yq version was accepted: $version"}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('phase12b-host-test-'+[guid]::NewGuid().ToString('N'))
$oldPath=$null
function Assert-Throws([scriptblock]$Block,[string]$Message){try{& $Block}catch{return};throw $Message}
try {
  $runtime=Join-Path $root 'runtime';$execution=Join-Path $root 'execution';$profile=Join-Path $root 'profile';$runnerRoot=Join-Path $root 'runners';$area=Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1'
  if((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId host -ProfileRoot $profile -RunnerRoot $runnerRoot) -ne 'NEW'){throw 'NEW host classification failed'}
  New-Item -ItemType Directory -Path $runtime|Out-Null;if((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId host -ProfileRoot $profile -RunnerRoot $runnerRoot) -ne 'INCONSISTENT'){throw 'partial host was accepted'};Remove-Item -LiteralPath $runtime -Recurse -Force
  & $area -Action ensure -Root $execution|Out-Null;New-Item -ItemType Directory -Path $runtime,$profile,$runnerRoot -Force|Out-Null;@{schema=1;host_id='host';service_identity='NT AUTHORITY\NETWORK SERVICE';service_sid='S-1-5-20';execution_root=$execution;runtime_root=$runtime}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runtime 'runtime.json') -NoNewline
  if((Get-Phase12BHostState -RuntimeRoot $runtime -ExecutionRoot $execution -HostId host -ProfileRoot $profile -RunnerRoot $runnerRoot) -ne 'EXISTING'){throw 'EXISTING host classification failed'}
  # Fresh production Onboard uses the same operation-bound atomic package
  # contract as migration.  The argument builder is the production call path,
  # while the no-op ACL callback is the only test provider substitution.
  $onboardPackage=Join-Path $root 'onboard-runner.zip'
  $onboardPackageSource=Join-Path $root 'onboard-package-source';New-Item -ItemType Directory -Path (Join-Path $onboardPackageSource 'bin') -Force|Out-Null
  foreach($relative in @('config.cmd','run.cmd','bin\Runner.Listener.exe','bin\RunnerService.exe')){New-Item -ItemType File -Path (Join-Path $onboardPackageSource $relative) -Force|Out-Null}
  Compress-Archive -Path (Join-Path $onboardPackageSource '*') -DestinationPath $onboardPackage
  $onboardHost=[pscustomobject]@{HostId='host';RunnerRoot=$runnerRoot;RunnerPackagePath=$onboardPackage}
  $onboardIdentity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $runnerRoot -RepositoryId '12345'
  $onboardArguments=Get-Phase12BFixedRunnerAdapterArguments -Action InstallPackage -Host $onboardHost -Identity $onboardIdentity -RepositoryFullName 'owner/repo' -RepositoryId '12345'
  if([string]$onboardArguments.HostRunnerRoot -cne $runnerRoot -or [string]$onboardArguments.RunnerRoot -cne $onboardIdentity.RunnerDirectory -or [string]$onboardArguments.RunnerPackagePath -cne $onboardPackage){throw 'Fresh Onboard canonical package arguments were not propagated.'}
  $operationId=[string]$onboardArguments.OperationId;$parsedOperation=[guid]::Empty
  if(-not[guid]::TryParseExact($operationId,'D',[ref]$parsedOperation)){throw 'Fresh Onboard package operation ID is not filesystem-safe.'}
  $retryArguments=Get-Phase12BFixedRunnerAdapterArguments -Action InstallPackage -Host $onboardHost -Identity $onboardIdentity -RepositoryFullName 'owner/repo' -RepositoryId '12345'
  if([string]$retryArguments.OperationId -cne $operationId){throw 'Fresh Onboard package operation ID changed across retries.'}
  if((Get-Phase12BOnboardPackageOperationId -HostId host -RepositoryId 67890) -ceq $operationId){throw 'Fresh Onboard package operation ID is not repository-scoped.'}
  $partialStage=Join-Path $runnerRoot ".migration-staging\$operationId\runner";New-Item -ItemType Directory -Path $partialStage -Force|Out-Null;New-Item -ItemType File -Path (Join-Path $partialStage 'partial.tmp')|Out-Null
  $onboardHostRoot=[string]$onboardArguments.HostRunnerRoot;$onboardTarget=[string]$onboardArguments.RunnerRoot;$onboardPackageInput=[string]$onboardArguments.RunnerPackagePath
  $publish=Install-Phase12BRunnerPackageAtomically -RunnerRoot $onboardHostRoot -TargetRunnerDirectory $onboardTarget -OperationId $operationId -PackagePath $onboardPackageInput -ApplyAcl {}
  if($publish.State -ne 'PUBLISHED' -or -not(Test-Phase12BRunnerPackageTree $onboardIdentity.RunnerDirectory)){throw 'Fresh Onboard partial staging did not recover through atomic publication.'}
  if((Install-Phase12BRunnerPackageAtomically -RunnerRoot $onboardHostRoot -TargetRunnerDirectory $onboardTarget -OperationId $operationId -PackagePath $onboardPackageInput -ApplyAcl {}).State -ne 'ALREADY_PUBLISHED'){throw 'Fresh Onboard post-publication retry was not idempotent.'}
  Assert-Throws {Get-Phase12BFixedRunnerAdapterArguments -Action InstallPackage -Host ([pscustomobject]@{HostId='host';RunnerRoot='';RunnerPackagePath=$onboardPackage}) -Identity $onboardIdentity -RepositoryFullName 'owner/repo' -RepositoryId '12345'} 'missing HostRunnerRoot was accepted'
  $wrongHostRoot=Join-Path $root 'wrong-runner-root';New-Item -ItemType Directory -Path $wrongHostRoot|Out-Null
  Assert-Throws {Get-Phase12BFixedRunnerAdapterArguments -Action InstallPackage -Host ([pscustomobject]@{HostId='host';RunnerRoot=$wrongHostRoot;RunnerPackagePath=$onboardPackage}) -Identity $onboardIdentity -RepositoryFullName 'owner/repo' -RepositoryId '12345'} 'HostRunnerRoot mismatch was accepted'
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $runnerRoot -TargetRunnerDirectory (Join-Path $root 'outside-runner-root') -OperationId $operationId -PackagePath $onboardPackage} 'target outside HostRunnerRoot was accepted'
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $runnerRoot -TargetRunnerDirectory (Join-Path $runnerRoot 'repo-67890') -OperationId '' -PackagePath $onboardPackage} 'missing OperationId was accepted'
  $partialFinal=Join-Path $runnerRoot 'repo-67890';New-Item -ItemType Directory -Path $partialFinal|Out-Null;New-Item -ItemType File -Path (Join-Path $partialFinal 'partial.tmp')|Out-Null
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $runnerRoot -TargetRunnerDirectory $partialFinal -OperationId (Get-Phase12BOnboardPackageOperationId -HostId host -RepositoryId 67890) -PackagePath $onboardPackage} 'Fresh Onboard partial final root was accepted'
  $unknownStaging=Join-Path $runnerRoot '.migration-staging\unknown-operation';New-Item -ItemType Directory -Path $unknownStaging -Force|Out-Null
  Assert-Throws {Install-Phase12BRunnerPackageAtomically -RunnerRoot $runnerRoot -TargetRunnerDirectory (Join-Path $runnerRoot 'repo-67891') -OperationId (Get-Phase12BOnboardPackageOperationId -HostId host -RepositoryId 67891) -PackagePath $onboardPackage} 'Fresh Onboard unknown staging was accepted'
  if(-not(Test-Path -LiteralPath $unknownStaging -PathType Container)){throw 'Fresh Onboard unknown staging was deleted.'}
  if((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$true -GitHubPresent:$true -ExpectedRepositoryId 1 -ActualRepositoryId 2 -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @('X64') -ActualLabels @('X64')) -ne 'INCONSISTENT'){throw 'wrong repository ID was accepted'}
  if((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$true -GitHubPresent:$true -ExpectedRepositoryId 1 -ActualRepositoryId 1 -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @('X64') -ActualLabels @('Windows')) -ne 'INCONSISTENT'){throw 'wrong labels were accepted'}
  if((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$true -GitHubPresent:$true -ExpectedRepositoryId 1 -ActualRepositoryId 1 -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @('X64') -ActualLabels @('X64') -ExpectedPathName 'a\run.cmd' -ActualPathName 'b\run.cmd') -ne 'INCONSISTENT'){throw 'wrong PathName was accepted'}
  if((Get-Phase12BRunnerState -LocalPresent:$true -ServicePresent:$true -GitHubPresent:$true -ExpectedRepositoryId 1 -ActualRepositoryId 1 -ActualServiceIdentity 'NT AUTHORITY\NETWORK SERVICE' -ExpectedLabels @('X64') -ActualLabels @('X64') -GitHubCount 2) -ne 'INCONSISTENT'){throw 'duplicate runner was accepted'}
  $serviceRoot=Join-Path $root 'service-runner';New-Item -ItemType Directory -Path (Join-Path $serviceRoot 'bin') -Force|Out-Null
  Set-Content -LiteralPath (Join-Path $serviceRoot '.service') -Value 'actions.runner.owner-repo.codex-repo-12345' -NoNewline;Set-Content -LiteralPath (Join-Path $serviceRoot 'bin\RunnerService.exe') -Value fixture -NoNewline
  $expectedService=Get-Phase12BExpectedServiceName $serviceRoot
  $serviceRecord=[pscustomobject]@{Name=$expectedService;PathName=('"{0}"' -f (Join-Path $serviceRoot 'bin\RunnerService.exe'));StartName='NT AUTHORITY\NETWORK SERVICE';State='Running'}
  if((Get-Phase12BServiceForRunner -RunnerRoot $serviceRoot -ServiceRecords @($serviceRecord)).Classification -ne 'EXISTING'){throw 'exact service grounding failed'}
  $wrongName=[pscustomobject]@{Name='actions.runner.someone-else';PathName=$serviceRecord.PathName;StartName=$serviceRecord.StartName;State=$serviceRecord.State}
  if((Get-Phase12BServiceForRunner -RunnerRoot $serviceRoot -ServiceRecords @($wrongName)).Classification -ne 'INCONSISTENT'){throw 'wrong Windows service name was accepted'}
  $wrongPath=[pscustomobject]@{Name=$expectedService;PathName='"C:\\other\\RunnerService.exe"';StartName=$serviceRecord.StartName;State=$serviceRecord.State}
  if((Get-Phase12BServiceForRunner -RunnerRoot $serviceRoot -ServiceRecords @($wrongPath)).Classification -ne 'INCONSISTENT'){throw 'wrong Windows service path was accepted'}
  $wrongIdentity=[pscustomobject]@{Name=$expectedService;PathName=$serviceRecord.PathName;StartName='LocalSystem';State='Running'}
  if((Get-Phase12BServiceForRunner -RunnerRoot $serviceRoot -ServiceRecords @($wrongIdentity)).Classification -ne 'INCONSISTENT'){throw 'wrong Windows service identity was accepted'}
  $duplicate=[pscustomobject]@{Name='actions.runner.duplicate';PathName=$serviceRecord.PathName;StartName=$serviceRecord.StartName;State='Running'}
  if((Get-Phase12BServiceForRunner -RunnerRoot $serviceRoot -ServiceRecords @($serviceRecord,$duplicate)).Classification -ne 'INCONSISTENT'){throw 'duplicate Windows service mapping was accepted'}
  if(-not(Test-Phase12BAclPolicy -Principals @('NT AUTHORITY\NETWORK SERVICE','BUILTIN\Administrators','NT AUTHORITY\SYSTEM'))){throw 'ACL positive failed'};if(Test-Phase12BAclPolicy -Principals @('NT AUTHORITY\NETWORK SERVICE','BUILTIN\Administrators','NT AUTHORITY\SYSTEM','Everyone')){throw 'broad ACL accepted'}
  $aclRules=@('NT AUTHORITY\NETWORK SERVICE','BUILTIN\Administrators','NT AUTHORITY\SYSTEM'|ForEach-Object{[pscustomobject]@{IdentityReference=[pscustomobject]@{Value=$_};IsInherited=$false;AccessControlType='Allow';FileSystemRights=[Security.AccessControl.FileSystemRights]::FullControl;InheritanceFlags=([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit);PropagationFlags='None'}})
  $acl=[pscustomobject]@{AreAccessRulesProtected=$true;Access=$aclRules}
  if(-not(Test-Phase12BAclPolicy -Acl $acl)){throw 'exact per-root ACL rules were rejected'}
  $badAcl=[pscustomobject]@{AreAccessRulesProtected=$true;Access=@($aclRules|ForEach-Object{$_.PSObject.Copy()})};$badAcl.Access[0].InheritanceFlags=[Security.AccessControl.InheritanceFlags]::None;if(Test-Phase12BAclPolicy -Acl $badAcl){throw 'ACL inheritance mismatch was accepted'}
  $inheritanceEnabled=[pscustomobject]@{AreAccessRulesProtected=$false;Access=$aclRules};if(Test-Phase12BAclPolicy -Acl $inheritanceEnabled){throw 'ACL inheritance enabled state was accepted'}
  $inheritedEveryone=[pscustomobject]@{AreAccessRulesProtected=$true;Access=@($aclRules)+@([pscustomobject]@{IdentityReference=[pscustomobject]@{Value='Everyone'};IsInherited=$true;AccessControlType='Allow';FileSystemRights=[Security.AccessControl.FileSystemRights]::FullControl;InheritanceFlags=([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit);PropagationFlags='None'})};if(Test-Phase12BAclPolicy -Acl $inheritedEveryone){throw 'unexpected inherited Everyone ACE was accepted'}
  foreach($mutation in @('extra','missing','duplicate','rights','propagation','deny')){
    $rules=@($aclRules|ForEach-Object{$_.PSObject.Copy()})
    switch($mutation){'extra'{$rules+=([pscustomobject]@{IdentityReference=[pscustomobject]@{Value='Everyone'};IsInherited=$false;AccessControlType='Allow';FileSystemRights=[Security.AccessControl.FileSystemRights]::FullControl;InheritanceFlags=([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit);PropagationFlags='None'})}'missing'{$rules=@($rules|Select-Object -Skip 1)}'duplicate'{$rules+=($rules[0].PSObject.Copy())}'rights'{$rules[0].FileSystemRights=[Security.AccessControl.FileSystemRights]::Read}'propagation'{$rules[0].PropagationFlags='InheritOnly'}'deny'{$rules[0].AccessControlType='Deny'}}
    if(Test-Phase12BAclPolicy -Acl ([pscustomobject]@{AreAccessRulesProtected=$true;Access=$rules})){throw "ACL $mutation mismatch was accepted"}
  }
  if(-not(Test-Phase12BFileAttributesSafe ([IO.FileAttributes]::Directory))){throw 'normal filesystem attributes were rejected'}
  if(Test-Phase12BFileAttributesSafe ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)){throw 'reparse-point attributes were accepted'}
  $localExecutionPath=Join-Path $PSScriptRoot '..\self-hosted\local-execution.ps1';$parseErrors=$null;$parseTokens=$null;$localAst=[Management.Automation.Language.Parser]::ParseFile($localExecutionPath,[ref]$parseTokens,[ref]$parseErrors)
  $mutexFunction=@($localAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-MutexSecurity'},$true));if($mutexFunction.Count -ne 1){throw 'production MutexSecurity constructor was not uniquely found'}
  Invoke-Expression $mutexFunction[0].Extent.Text;$networkServiceSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-20');$mutexSecurity=New-MutexSecurity $networkServiceSid
  $mutexRules=@($mutexSecurity.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));if($mutexRules.Count -ne 1 -or $mutexRules[0].IdentityReference.Value -cne 'S-1-5-20' -or $mutexRules[0].MutexRights -ne [Security.AccessControl.MutexRights]::FullControl -or $mutexRules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow){throw 'production mutex ACL construction is not exact NETWORK SERVICE full control'}
  $adapter=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runner-adapter.ps1') -Raw
  foreach($text in 'InstallPackage','StartService','StopService','Unregister','RemoveService','Assert-ServicePath','RunnerPackagePath','HostRunnerRoot','OperationId','Install-Phase12BRunnerPackageAtomically','registration-token','remove-token','--runasservice','--windowslogonaccount','RunnerService.exe','.service'){if($adapter -notmatch [regex]::Escape($text)){throw "runner lifecycle stage missing: $text"}}
  foreach($forbidden in 'sc.exe create','cmd.exe /c'){if($adapter -match [regex]::Escape($forbidden)){throw "non-official service host remains: $forbidden"}}
  foreach($text in 'CODEX_RUNNER_PACKAGE_PATH','CODEX_RUNNER_TOKEN_COMMAND'){if($adapter -match [regex]::Escape($text)){throw "operator environment remained runner authority: $text"}}
  foreach($file in 'bootstrap-host.ps1','migrate-host.ps1','verify-host.ps1'){ $text=Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -Raw;if($text -match 'NOT_IMPLEMENTED_BATCH_A|CREATE_RUNNERS=false|INSTALL_WINDOWS_SERVICES=false|\[string\]\$RunnerAdapter' -or ($file -eq 'bootstrap-host.ps1' -and $text -match '\[string\]\$RunnerPackagePath')){throw "unsafe or empty apply path remains: $file"} }
  # A constrained yq v4 double provides a complete desired-state fixture. No real tool or host is used.
  $runnerPackage=Join-Path $root 'runner-package.zip';$runnerPackageSource=Join-Path $root 'runner-package-source';New-Item -ItemType Directory -Path (Join-Path $runnerPackageSource 'bin') -Force|Out-Null
  foreach($relative in @('config.cmd','run.cmd','bin\Runner.Listener.exe','bin\RunnerService.exe')){New-Item -ItemType File -Path (Join-Path $runnerPackageSource $relative) -Force|Out-Null}
  Compress-Archive -Path (Join-Path $runnerPackageSource '*') -DestinationPath $runnerPackage
  $bin=Join-Path $root 'bin';New-Item -ItemType Directory -Path $bin|Out-Null
  @'
@echo off
if "%1"=="--version" (echo yq version 4.44.1&exit /b 0)
set q=%2
if "%q%"==".schema_version" echo 1
if "%q%"==".host.config" echo host.yaml
if "%q%"==".host_id" echo host
if "%q%"==".platform" echo windows
if "%q%"==".paths.execution_root" echo __EXEC__
if "%q%"==".paths.runner_root" echo __RUNNERS__
if "%q%"==".paths.runtime_root" echo __RUNTIME__
if "%q%"==".paths.profile_root" echo __PROFILE__
if "%q%"==".runner.mode" echo windows-service
if "%q%"==".runner.service_identity" echo network-service
if "%q%"==".runner.service_sid" echo S-1-5-20
if "%q%"==".runner.package_path" echo __PACKAGE__
if "%q%"==".execution.serialization" echo global-mutex
if "%q%"==".runner.labels[]" (echo self-hosted&echo Windows&echo X64&echo codex-automation)
if "%q%"==".github.owner_id" echo 32902649
if "%q%"==".google_cloud.project_id" echo codex-automation-506111
if "%q%"==".google_cloud.workload_identity_provider_resource" echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions
if "%q%"==".automation.repository" echo kusa07/codex-automation
if "%q%"==".automation.workflow_path" echo .github/workflows/codex-run.yml
if "%q%"==".automation.active_workflow_sha" echo 352857a387b1f855920fb8d1587091b31e518c21
if "%q%"==".repository.full_name" echo kusa07/example
if "%q%"==".repository.id" echo 12345
if "%q%"==".secret.id" echo codex-auth-example
if "%q%"==".workflow.path" echo .github/workflows/codex-connectivity-test.yml
if "%q%"==".runner.enabled" echo true
if "%q%"==".runner.scope" echo repository
'@.Replace('__EXEC__',$execution).Replace('__RUNNERS__',$runnerRoot).Replace('__RUNTIME__',$runtime).Replace('__PROFILE__',$profile).Replace('__PACKAGE__',$runnerPackage)|Set-Content -LiteralPath (Join-Path $bin 'yq.cmd') -NoNewline
  New-Item -ItemType Directory -Path (Join-Path $root 'callers')|Out-Null;New-Item -ItemType File -Path (Join-Path $root 'environment.yaml'),(Join-Path $root 'host.yaml'),(Join-Path $root 'callers/example.yaml')|Out-Null
  $rendered=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\templates\caller\codex-connectivity-test.yml.tpl')).Replace('__AUTOMATION_REPOSITORY__','kusa07/codex-automation').Replace('__AUTOMATION_WORKFLOW_PATH__','.github/workflows/codex-run.yml').Replace('__AUTOMATION_WORKFLOW_SHA__','352857a387b1f855920fb8d1587091b31e518c21').Replace('__GOOGLE_CLOUD_PROJECT_ID__','codex-automation-506111').Replace('__WORKLOAD_IDENTITY_PROVIDER__','projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions').Replace('__CODEX_AUTH_SECRET_ID__','codex-auth-example');$content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rendered))
  $member='principalSet://iam.googleapis.com/projects/896979145485/locations/global/workloadIdentityPools/github/attribute.repository_id/12345'
  @{RepositoryId='12345';RepositoryFullName='kusa07/example';DefaultBranch='main';WorkflowBranch='main';Runners=@(@{name='codex-repo-12345';labels=@(@{name='self-hosted'},@{name='Windows'},@{name='X64'},@{name='codex-automation'})});WorkflowContent=$content;SecretVersions=@(@{name='projects/x/secrets/codex-auth-example/versions/1';state='ENABLED'});Iam=@{bindings=@(@{role='roles/secretmanager.secretAccessor';members=@($member)},@{role='roles/secretmanager.secretVersionManager';members=@($member)})};Provider=@{attributeCondition="assertion.repository_owner_id == '32902649' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21']"}}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'external.json') -NoNewline
  $callerRunnerRoot=Join-Path $runnerRoot 'repo-12345';$serviceFixture=@(@{Name='actions.runner.kusa07-example.codex-repo-12345';PathName=('"{0}"' -f (Join-Path $callerRunnerRoot 'bin\RunnerService.exe'));StartName='NT AUTHORITY\NETWORK SERVICE';State='Running'})
  $serviceFixture|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'services.json') -NoNewline
  # Bootstrap must see a wholly NEW host; prior classification fixtures are removed.
  Remove-Item -LiteralPath $runtime,$execution,$profile,$runnerRoot -Recurse -Force
  $oldPath=$env:PATH;$env:PATH="$bin;$oldPath";$log=Join-Path $root 'adapter.log'
  & (Join-Path $PSScriptRoot 'bootstrap-host.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -TestMode -FixtureRoot $root -AdapterLog $log -ExternalReadbackFile (Join-Path $root 'external.json') -ServiceReadbackFile (Join-Path $root 'services.json')|Out-Null
  $ordered=(Get-Content -LiteralPath $log -Raw);foreach($stage in 'EnsureDirectory','WriteRuntime','EnsureExecutionArea','ApplyAcl'){if($ordered -notmatch "ACTION=$stage"){throw "NEW bootstrap host stage missing: $stage"}}
  $bootstrapMetadata=Read-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName kusa07/example -RunnerRoot $runnerRoot;if($bootstrapMetadata.lifecycle_state -ne 'ACTIVE'){throw 'bootstrap did not create canonical ACTIVE metadata'}
  # Production-shaped existing-host apply: the same CLI constructs canonical
  # Host/Caller/Service/runner identities; only external reads/mutations are
  # replaced by a bounded fixture provider.
  $runtimeReadback=Join-Path $root 'runtime-readback.json'
  $applyFixture=[ordered]@{schema=1;repository_id='12345';repository_full_name='kusa07/example';runner_id='22';runner_name='codex-repo-12345';runner_online_idle=$true;service_name='actions.runner.kusa07-example.codex-repo-12345';service_identity='NT AUTHORITY\NETWORK SERVICE';service_state='Running';workflow_exact=$true;dispatch_state='active';quiescent=$true;quiescence_reason='NO_CURRENT_EXECUTION';package_verified=$false;unknown_state=$false;fail_action='';runtime_observation=[ordered]@{DirectoryPresent=$false;DirectoryIsContainer=$false;DirectoryNonReparse=$true;LeafPresent=$false;LeafNonReparse=$true;SignatureValid=$false;Version='';X64=$false;MachinePath='MISSING'};mutation_calls=@()}
  $applyFixture|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $runtimeReadback -NoNewline
  $otherCaller=$applyFixture|ConvertTo-Json -Depth 8|ConvertFrom-Json;$otherCaller.quiescence_reason='OTHER_CALLER_EXECUTION';$otherCaller|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $runtimeReadback -NoNewline
  Assert-Throws {& (Join-Path $PSScriptRoot 'apply-system-runtime.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -TestMode -FixtureRoot $root -RuntimeReadbackFile $runtimeReadback|Out-Null} 'Machine-wide runtime change accepted another caller execution.'
  if(Test-Path -LiteralPath (Join-Path $runtime 'system-runtime\powershell7-intent.json')){throw 'Other-caller execution created runtime intent.'}
  $applyFixture|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $runtimeReadback -NoNewline
  & (Join-Path $PSScriptRoot 'apply-system-runtime.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -TestMode -FixtureRoot $root -RuntimeReadbackFile $runtimeReadback|Out-Null
  $applyAfter=Get-Content -LiteralPath $runtimeReadback -Raw|ConvertFrom-Json
  foreach($action in @('FenceDispatch','VerifyPackage','InstallRuntime','StopService','StartService','RestoreDispatch')){if($action -notin @($applyAfter.mutation_calls)){throw "Production-shaped runtime apply omitted $action."}}
  if([string]$applyAfter.runner_id -cne '22' -or [string]$applyAfter.service_identity -cne 'NT AUTHORITY\NETWORK SERVICE' -or [string]$applyAfter.dispatch_state -cne 'active'){throw 'Production-shaped runtime apply changed runner, Service, or dispatch authority.'}
  Assert-Throws {& (Join-Path $PSScriptRoot 'apply-system-runtime.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -RuntimeReadbackFile $runtimeReadback|Out-Null} 'Production runtime apply accepted fixture injection.'
  $pythonReadback=Join-Path $root 'python-readback.json'
  $pythonFixture=$applyFixture|ConvertTo-Json -Depth 8|ConvertFrom-Json
  $pythonFixture.runtime_observation.PSObject.Properties.Remove('MachinePath')
  $pythonFixture.runtime_observation|Add-Member -NotePropertyName PathIsolated -NotePropertyValue $true
  $pythonFixture|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $pythonReadback -NoNewline
  & (Join-Path $PSScriptRoot 'apply-system-python.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -TestMode -FixtureRoot $root -RuntimeReadbackFile $pythonReadback|Out-Null
  $pythonAfter=Get-Content -LiteralPath $pythonReadback -Raw|ConvertFrom-Json
  foreach($action in @('FenceDispatch','VerifyPackage','InstallRuntime','StopService','StartService','RestoreDispatch')){if($action -notin @($pythonAfter.mutation_calls)){throw "Production-shaped Python apply omitted $action."}}
  if([string]$pythonAfter.runner_id -cne '22' -or [string]$pythonAfter.dispatch_state -cne 'active' -or [string]$pythonAfter.runtime_observation.Version -cne '3.13.15'){throw 'Python apply changed runner/dispatch identity or missed exact version.'}
  $pythonIntentPath=Join-Path $runtime 'system-python\python313-intent.json'
  $pythonIntent=Get-Content -LiteralPath $pythonIntentPath -Raw|ConvertFrom-Json
  $originalPathHash=$pythonIntent.machine_path_sha256
  $pythonIntent.machine_path_sha256='0'*64
  $pythonIntent|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $pythonIntentPath -NoNewline
  $pythonAfter.mutation_calls=@()
  $pythonAfter|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $pythonReadback -NoNewline
  Assert-Throws {& (Join-Path $PSScriptRoot 'apply-system-python.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -TestMode -FixtureRoot $root -RuntimeReadbackFile $pythonReadback|Out-Null} 'Changed machine PATH hash was allowed before Python resume mutation.'
  if(@((Get-Content -LiteralPath $pythonReadback -Raw|ConvertFrom-Json).mutation_calls).Count -ne 0){throw 'PATH mismatch triggered Python provider mutation.'}
  $pythonIntent.machine_path_sha256=$originalPathHash
  $pythonIntent|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $pythonIntentPath -NoNewline
  Assert-Throws {& (Join-Path $PSScriptRoot 'apply-system-python.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -RuntimeReadbackFile $pythonReadback|Out-Null} 'Production Python apply accepted fixture injection.'
  Assert-Throws { & (Join-Path $PSScriptRoot 'bootstrap-host.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -AdapterLog $log -ExternalReadbackFile (Join-Path $root 'external.json') -ServiceReadbackFile (Join-Path $root 'services.json')|Out-Null } 'production path accepted AdapterLog'
  $env:PHASE12B_TEST_ADAPTER='1';Assert-Throws { & (Join-Path $PSScriptRoot 'bootstrap-host.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') } 'environment-only test adapter activation accepted';Remove-Item Env:PHASE12B_TEST_ADAPTER
  # Synthetic existing host makes migration prove it grounds and passes its actual service name to the adapter.
  & $area -Action ensure -Root $execution|Out-Null;New-Item -ItemType Directory -Path $runtime,$profile,$runnerRoot -Force|Out-Null;@{schema=1;host_id='host';service_identity='NT AUTHORITY\NETWORK SERVICE';service_sid='S-1-5-20';execution_root=$execution;runtime_root=$runtime}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runtime 'runtime.json') -NoNewline
  $migratedRoot=Join-Path $runnerRoot 'repo-12345';New-Item -ItemType Directory -Path (Join-Path $migratedRoot 'bin') -Force|Out-Null;New-Item -ItemType File -Path (Join-Path $migratedRoot '.runner') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $migratedRoot '.service') -Value 'actions.runner.kusa07-example.codex-repo-12345' -NoNewline;Set-Content -LiteralPath (Join-Path $migratedRoot 'bin\RunnerService.exe') -Value fixture -NoNewline
  $activeMetadata=Get-Phase12BRunnerMetadataPath -RuntimeRoot $runtime -RepositoryId 12345;if(Test-Path -LiteralPath $activeMetadata){Remove-Item -LiteralPath $activeMetadata -Force};Write-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName 'kusa07/example' -RunnerRoot $runnerRoot -LifecycleState ACTIVE -ServiceName (Get-Phase12BExpectedServiceName $migratedRoot)|Out-Null
  $migrateLog=Join-Path $root 'migrate.log';& (Join-Path $PSScriptRoot 'migrate-host.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -Approve -TestMode -FixtureRoot $root -AdapterLog $migrateLog -ExternalReadbackFile (Join-Path $root 'external.json') -ServiceReadbackFile (Join-Path $root 'services.json')|Out-Null;$migratedMetadata=Read-Phase12BRunnerMetadata -RuntimeRoot $runtime -RepositoryId 12345 -RepositoryFullName kusa07/example -RunnerRoot $runnerRoot;if($migratedMetadata.lifecycle_state -ne 'ACTIVE'){throw 'migration did not route through canonical ACTIVE lifecycle'}
  $cfg=Read-Phase12BConfig (Join-Path $root 'environment.yaml')
  $wifExpected="assertion.repository_owner_id == '32902649' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21']"
  if(-not(Test-Phase12BWifCondition -Condition $wifExpected -OwnerId '32902649' -WorkflowIdentity 'kusa07/codex-automation/.github/workflows/codex-run.yml' -ActiveSha '352857a387b1f855920fb8d1587091b31e518c21')){throw 'canonical WIF condition was rejected'}
  foreach($wifInvalid in @(
    "assertion.repository_owner_id == '999999' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21']",
    "assertion.repository_owner_id == '32902649' && assertion.job_workflow_ref.startsWith('other/repo/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21']",
    "assertion.repository_owner_id == '32902649' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['0000000000000000000000000000000000000000']",
    "assertion.repository_owner_id == '32902649' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21','352857a387b1f855920fb8d1587091b31e518c21']",
    "assertion.repository_owner_id == '32902649' || assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21']",
    "assertion.repository_owner_id == '32902649' && assertion.job_workflow_ref.startsWith('kusa07/codex-automation/.github/workflows/codex-run.yml@') && assertion.job_workflow_sha in ['352857a387b1f855920fb8d1587091b31e518c21']`n"
  )){if(Test-Phase12BWifCondition -Condition $wifInvalid -OwnerId '32902649' -WorkflowIdentity 'kusa07/codex-automation/.github/workflows/codex-run.yml' -ActiveSha '352857a387b1f855920fb8d1587091b31e518c21'){throw 'invalid WIF condition was accepted'}}
  # Production-shaped external read-back fixture: assert scalar project/pool/
  # provider arguments instead of relying on the TestMode external shortcut.
  $ghLog=Join-Path $root 'gh-args.log';$gcloudLog=Join-Path $root 'gcloud-args.log'
  $ghMock=@'
@echo off
>>"%PHASE12B_GH_ARGS_LOG%" echo %*
if "%~1"=="api" if "%~2"=="--paginate" (echo [{"total_count":0,"runners":[]} ]&exit /b 0)
if "%~1"=="api" if not "%~2"=="--paginate" if not "%~2"=="--method" (echo {"id":"12345","full_name":"kusa07/example","default_branch":"main","content":""}&exit /b 0)
if "%~1"=="api" if "%~2"=="--method" (echo {"ok":true}&exit /b 0)
exit /b 0
'@
  $gcloudMock=@'
@echo off
>>"%PHASE12B_GCLOUD_ARGS_LOG%" echo %*
if "%~1"=="secrets" if "%~2"=="versions" (echo []&exit /b 0)
if "%~1"=="secrets" if "%~2"=="get-iam-policy" (echo {"bindings":[]}&exit /b 0)
if "%~1"=="iam" (echo {"attributeCondition":"assertion.repository_owner_id == '32902649'"}&exit /b 0)
exit /b 0
'@
  Set-Content -LiteralPath (Join-Path $bin 'gh.cmd') -Value $ghMock -NoNewline;Set-Content -LiteralPath (Join-Path $bin 'gcloud.cmd') -Value $gcloudMock -NoNewline
  $oldPath=$env:PATH;$env:PATH="$bin;$oldPath";$env:PHASE12B_GH_ARGS_LOG=$ghLog;$env:PHASE12B_GCLOUD_ARGS_LOG=$gcloudLog
  try {
    $externalProduction=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0]
    $gcloudArgs=Get-Content -LiteralPath $gcloudLog -Raw
    if($gcloudArgs -notmatch '--project=codex-automation-506111' -or $gcloudArgs -notmatch '--workload-identity-pool=github' -or $gcloudArgs -notmatch 'providers describe github-actions'){throw 'production gcloud argument projection was not scalar and exact'}
  } finally {$env:PATH=$oldPath;Remove-Item Env:PHASE12B_GH_ARGS_LOG,Env:PHASE12B_GCLOUD_ARGS_LOG -ErrorAction SilentlyContinue}
  Remove-Item -LiteralPath (Join-Path $bin 'gh.cmd'),(Join-Path $bin 'gcloud.cmd') -Force
  $identityBroken=Get-Content -LiteralPath (Join-Path $root 'external.json') -Raw|ConvertFrom-Json;$identityBroken.RepositoryFullName='kusa07/other';$identityBrokenFile=Join-Path $root 'broken-repository-full-name.json';$identityBroken|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $identityBrokenFile -NoNewline
  $identityExternal=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $identityBrokenFile
  if((Test-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -External $identityExternal -RunnerName 'codex-repo-12345').Repository -eq 'PASS'){throw 'repository full_name mismatch was accepted'}
  $identityMissing=Get-Content -LiteralPath (Join-Path $root 'external.json') -Raw|ConvertFrom-Json;$identityMissing.PSObject.Properties.Remove('RepositoryFullName');$identityMissingFile=Join-Path $root 'missing-repository-full-name.json';$identityMissing|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $identityMissingFile -NoNewline
  $identityMissingExternal=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $identityMissingFile
  if((Test-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -External $identityMissingExternal -RunnerName 'codex-repo-12345').Repository -eq 'PASS'){throw 'missing repository full_name was accepted'}
  foreach($field in 'Provider','SecretVersions','Iam','WorkflowContent'){
    $broken=Get-Content -LiteralPath (Join-Path $root 'external.json') -Raw|ConvertFrom-Json
    switch($field){'Provider'{$broken.Provider.attributeCondition='wrong'}'SecretVersions'{$broken.SecretVersions=$null}'Iam'{$broken.Iam=@{bindings=@()}}'WorkflowContent'{$broken.WorkflowContent=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('wrong'))}}
    $badFile=Join-Path $root ("broken-$field.json");$broken|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $badFile -NoNewline;$ext=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $badFile
    if((Test-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -External $ext -RunnerName 'codex-repo-12345').All){throw "$field read-back failure was accepted"}
  }
  $branchBroken=Get-Content -LiteralPath (Join-Path $root 'external.json') -Raw|ConvertFrom-Json;$branchBroken.WorkflowBranch='release';$branchFile=Join-Path $root 'broken-branch.json';$branchBroken|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $branchFile -NoNewline
  $branchExternal=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $branchFile
  if((Test-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -External $branchExternal -RunnerName 'codex-repo-12345').All){throw 'caller workflow branch mismatch was accepted'}
  $verifyMalformed=Join-Path $root 'verify-malformed-external.json';Set-Content -LiteralPath $verifyMalformed -Value '{' -NoNewline
  $verifyOutput=@(& (Join-Path $PSScriptRoot 'verify-host.ps1') -PrivateConfig (Join-Path $root 'environment.yaml') -TestMode -FixtureRoot $root -ExternalReadbackFile $verifyMalformed -ServiceReadbackFile (Join-Path $root 'services.json') 2>&1)
  if($LASTEXITCODE -ne 2 -or ($verifyOutput -join "`n") -notmatch 'WORKFLOW_BRANCH=UNKNOWN'){throw 'verify-host malformed external read-back was not fail-closed with observable output'}
  $multiSecret=Get-Content -LiteralPath (Join-Path $root 'external.json') -Raw|ConvertFrom-Json;$multiSecret.SecretVersions=@(@{name='projects/x/secrets/codex-auth-example/versions/1';state='ENABLED'},@{name='projects/x/secrets/codex-auth-example/versions/2';state='ENABLED'});$multiFile=Join-Path $root 'broken-multiple-secret.json';$multiSecret|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $multiFile -NoNewline
  $multiExternal=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $multiFile
  if((Test-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -External $multiExternal -RunnerName 'codex-repo-12345').All){throw 'multiple enabled Secret versions were accepted'}
  $deceptiveIam=Get-Content -LiteralPath (Join-Path $root 'external.json') -Raw|ConvertFrom-Json;$deceptiveIam.Iam=@{bindings=@(@{role='roles/viewer';members=@("prefix-$member-suffix")})};$deceptiveIamFile=Join-Path $root 'broken-iam-substring.json';$deceptiveIam|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $deceptiveIamFile -NoNewline;$deceptiveExternal=Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $deceptiveIamFile;if((Test-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -External $deceptiveExternal -RunnerName 'codex-repo-12345').Iam -ne 'FAIL'){throw 'IAM substring deception was accepted'}
  $malformed=Join-Path $root 'malformed-external.json';Set-Content -LiteralPath $malformed -Value '{' -NoNewline
  Assert-Throws { Get-Phase12BExternalCallerState -Config $cfg -Caller $cfg.Callers[0] -TestMode -FixtureRoot $root -ExternalReadbackFile $malformed|Out-Null } 'malformed external read-back was accepted'
  'phase12b host state tests passed'
} finally { if($oldPath){$env:PATH=$oldPath};if(Test-Path Env:PHASE12B_TEST_ADAPTER){Remove-Item Env:PHASE12B_TEST_ADAPTER};if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force} }
