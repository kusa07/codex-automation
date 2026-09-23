Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Phase12BServiceIdentity = 'NT AUTHORITY\NETWORK SERVICE'
$script:Phase12BServiceSid = 'S-1-5-20'

function Test-Phase12BYqV4Version([string]$Version) {
    return $Version -cmatch '^(?:(?:yq|yq \(https://github\.com/mikefarah/yq/\))\s+)?version\s+v?4\.\d+\.\d+$'
}

function Test-Phase12BNoReparse([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) { if (-not(Test-Phase12BFileAttributesSafe $item.Attributes)) { return $false }; $item = if ($item -is [System.IO.FileInfo]) { $item.Directory } else { $item.Parent } }
    return $true
}
function Test-Phase12BFileAttributesSafe([System.IO.FileAttributes]$Attributes) {
    return (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}
function Get-Phase12BCallerRunnerRoot([string]$RunnerRoot,[string]$Repository) { if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid caller repository identity.' }; Join-Path $RunnerRoot ($Repository -replace '[^A-Za-z0-9_.-]','_') }
function Get-Phase12BExpectedRunnerName([string]$CallerRunnerRoot) { $leaf=[IO.Path]::GetFileName($CallerRunnerRoot);if($leaf -match '^repo-([1-9][0-9]*)$'){return "codex-repo-$($Matches[1])"};$leaf }
function Get-Phase12BExpectedServiceName([string]$CallerRunnerRoot) {
    $serviceFile=Join-Path $CallerRunnerRoot '.service'
    if(-not(Test-Path -LiteralPath $serviceFile -PathType Leaf) -or -not(Test-Phase12BNoReparse $serviceFile)){return ''}
    $name=(Get-Content -LiteralPath $serviceFile -Raw -ErrorAction Stop).Trim()
    if($name -notmatch '^actions\.runner\.[A-Za-z0-9_.-]+$'){throw 'Official runner .service metadata is invalid.'}
    $name
}
function Test-Phase12BServicePath([string]$PathName,[string]$RunnerRoot) {
    if([string]::IsNullOrWhiteSpace($PathName)){return $false}
    $hostExe=[regex]::Escape([IO.Path]::GetFullPath((Join-Path $RunnerRoot 'bin\RunnerService.exe')))
    return $PathName -match ('(?i)^\s*"?{0}"?\s*$' -f $hostExe)
}

function Test-Phase12BTestAdapter {
    param([switch]$TestMode,[string]$FixtureRoot,[string]$AdapterLog,[string]$ExternalReadbackFile,[string]$ServiceReadbackFile,[string]$MigrationReadbackFile)
    if(-not [string]::IsNullOrWhiteSpace($env:PHASE12B_TEST_ADAPTER)){throw 'Environment-based test adapter activation is prohibited.'}
    $testPaths=@(@($AdapterLog,$ExternalReadbackFile,$ServiceReadbackFile,$MigrationReadbackFile)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    if(-not $TestMode){if($testPaths.Count -ne 0 -or $FixtureRoot){throw 'Test adapters require explicit TestMode and FixtureRoot.'};return}
    $root=Assert-Phase12BFixtureRoot $FixtureRoot
    $prefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    foreach($testPath in $testPaths){$full=[IO.Path]::GetFullPath($testPath);$safetyPath=if(Test-Path -LiteralPath $full){$full}else{Split-Path -Parent $full};if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Phase12BNoReparse $safetyPath)){throw 'Test adapter state must remain beneath a non-reparse FixtureRoot.'}}
}
function Read-Phase12BRuntime([string]$RuntimeRoot) { $f=Join-Path $RuntimeRoot 'runtime.json';if(-not(Test-Path -LiteralPath $f -PathType Leaf) -or -not(Test-Phase12BNoReparse $f)){return $null};try{Get-Content -LiteralPath $f -Raw|ConvertFrom-Json -ErrorAction Stop}catch{return $null} }

function Get-Phase12BHostState {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$ExecutionRoot,[Parameter(Mandatory=$true)][string]$HostId,[string]$ProfileRoot,[string]$RunnerRoot)
    $roots=@($RuntimeRoot,$ExecutionRoot);if($ProfileRoot){$roots+=$ProfileRoot};if($RunnerRoot){$roots+=$RunnerRoot};$present=@($roots|Where-Object{Test-Path -LiteralPath $_})
    if($present.Count -eq 0){return 'NEW'};if($present.Count -ne $roots.Count -or @($roots|Where-Object{-not(Test-Phase12BNoReparse $_)}).Count -ne 0){return 'INCONSISTENT'}
    try{& (Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1') -Action inspect -Root $ExecutionRoot|Out-Null}catch{return 'INCONSISTENT'}
    $runtime=Read-Phase12BRuntime $RuntimeRoot;if($null -eq $runtime){return 'INCONSISTENT'};$expected=@{schema=1;host_id=$HostId;service_identity=$script:Phase12BServiceIdentity;service_sid=$script:Phase12BServiceSid;execution_root=$ExecutionRoot;runtime_root=$RuntimeRoot};foreach($k in $expected.Keys){if([string]$runtime.$k -cne [string]$expected[$k]){return 'INCONSISTENT'}};'EXISTING'
}
function Get-Phase12BServiceForRunner {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$RunnerRoot,[object[]]$ServiceRecords)
    $expectedName=Get-Phase12BExpectedServiceName $RunnerRoot
    if(-not(Test-Path -LiteralPath $RunnerRoot -PathType Container) -or -not(Test-Phase12BNoReparse $RunnerRoot)){return [pscustomobject]@{Classification='INCONSISTENT';Reason='RUNNER_ROOT';ExpectedServiceName=$expectedName;Services=@()}}
    try { $all=if($PSBoundParameters.ContainsKey('ServiceRecords')){@($ServiceRecords)}else{@(Get-CimInstance Win32_Service -ErrorAction Stop)} } catch { return [pscustomobject]@{Classification='UNKNOWN';Reason='SERVICE_READBACK_ERROR';ExpectedServiceName=$expectedName;Services=@()} }
    $named=@(if($expectedName){$all|Where-Object{[string]$_.Name -ieq $expectedName}})
    $mapped=@($all|Where-Object{Test-Phase12BServicePath ([string]$_.PathName) $RunnerRoot})
    if(-not $expectedName -and $mapped.Count -eq 0){return [pscustomobject]@{Classification='NEW';Reason='SERVICE_ABSENT';ExpectedServiceName='';Services=@()}}
    if(-not $expectedName -and $mapped.Count -gt 0){return [pscustomobject]@{Classification='INCONSISTENT';Reason='SERVICE_WITHOUT_OFFICIAL_SERVICE_METADATA';ExpectedServiceName='';Services=$mapped}}
    if($named.Count -eq 0 -and $mapped.Count -eq 0){return [pscustomobject]@{Classification='INCONSISTENT';Reason='OFFICIAL_SERVICE_METADATA_WITHOUT_SERVICE';ExpectedServiceName=$expectedName;Services=@()}}
    if($named.Count -ne 1){return [pscustomobject]@{Classification='INCONSISTENT';Reason='DUPLICATE_OR_MISSING_EXPECTED_SERVICE_NAME';ExpectedServiceName=$expectedName;Services=$all}}
    $s=$named[0]
    # A PathName match with a different service name is never a substitute for
    # the deterministic desired service identity.  It is an unsafe duplicate.
    if($mapped.Count -ne 1 -or [string]$mapped[0].Name -ine $expectedName){return [pscustomobject]@{Classification='INCONSISTENT';Reason='SERVICE_PATH_TO_NAME_MISMATCH';ExpectedServiceName=$expectedName;Services=$all;ServiceName=$s.Name;PathName=$s.PathName;Identity=$s.StartName;State=$s.State}}
    $pathOk=Test-Phase12BServicePath ([string]$s.PathName) $RunnerRoot
    $identityOk=$s.StartName -in @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')
    $stateOk=$s.State -in @('Running','Stopped')
    $c=if($pathOk -and $identityOk -and $stateOk){'EXISTING'}else{'INCONSISTENT'}
    [pscustomobject]@{Classification=$c;Reason=if($c -eq 'EXISTING'){'MATCH'}else{'SERVICE_CONTRADICTION'};ExpectedServiceName=$expectedName;Services=@($s);ServiceName=$s.Name;PathName=$s.PathName;Identity=$s.StartName;State=$s.State}
}
function Get-Phase12BRunnerState {
    [CmdletBinding()]param([bool]$LocalPresent,[bool]$ServicePresent,[bool]$GitHubPresent,[string]$ExpectedRepositoryId,[string]$ActualRepositoryId,[string]$ActualServiceIdentity,[string[]]$ExpectedLabels=@(),[string[]]$ActualLabels=@(),[string]$ExpectedPathName,[string]$ActualPathName,[string]$ExpectedServiceName,[string]$ActualServiceName,[int]$GitHubCount=1)
    if(-not $LocalPresent -and -not $ServicePresent -and -not $GitHubPresent){return 'NEW'};if(-not($LocalPresent -and $ServicePresent -and $GitHubPresent)){return 'INCONSISTENT'};if([string]::IsNullOrWhiteSpace($ExpectedRepositoryId) -or $ExpectedRepositoryId -cne $ActualRepositoryId -or $ExpectedLabels.Count -eq 0 -or $GitHubCount -ne 1){return 'INCONSISTENT'};if($ActualServiceIdentity -notin @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')){return 'INCONSISTENT'};if($ExpectedServiceName -and $ExpectedServiceName -ine $ActualServiceName){return 'INCONSISTENT'};if($ExpectedPathName -and $ActualPathName -notlike "*$ExpectedPathName*"){return 'INCONSISTENT'};if(@(Compare-Object ($ExpectedLabels|Sort-Object -Unique) ($ActualLabels|Sort-Object -Unique)).Count -ne 0){return 'INCONSISTENT'};'EXISTING'
}
function Test-Phase12BAclPolicy {
 [CmdletBinding(DefaultParameterSetName='Acl')]param(
  [Parameter(Mandatory=$true,ParameterSetName='Acl')][object]$Acl,
  [Parameter(Mandatory=$true,ParameterSetName='Rules')][object[]]$AccessRules,
  [Parameter(Mandatory=$true,ParameterSetName='Rules')][bool]$AreAccessRulesProtected,
  [Parameter(Mandatory=$true,ParameterSetName='Legacy')][string[]]$Principals
 )
 $expected=@($script:Phase12BServiceIdentity,'BUILTIN\Administrators','NT AUTHORITY\SYSTEM'|Sort-Object)
 if($PSCmdlet.ParameterSetName -eq 'Legacy'){return @(Compare-Object $expected @($Principals|Sort-Object -Unique)).Count -eq 0}
 if($PSCmdlet.ParameterSetName -eq 'Acl'){
  if(-not $Acl.PSObject.Properties['AreAccessRulesProtected'] -or -not $Acl.PSObject.Properties['Access']){return $false}
  $AreAccessRulesProtected=[bool]$Acl.AreAccessRulesProtected;$AccessRules=@($Acl.Access)
 }
 if(-not $AreAccessRulesProtected -or @($AccessRules|Where-Object{$_.IsInherited}).Count -ne 0 -or $AccessRules.Count -ne 3){return $false}
 $explicit=@($AccessRules)
 foreach($principal in $expected){
  $rules=@($explicit|Where-Object{[string]$_.IdentityReference.Value -ieq $principal})
  if($rules.Count -ne 1){return $false};$rule=$rules[0]
  if([string]$rule.AccessControlType -ne 'Allow' -or [Security.AccessControl.FileSystemRights]$rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){return $false}
  $requiredInheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
  if([Security.AccessControl.InheritanceFlags]$rule.InheritanceFlags -ne $requiredInheritance -or [string]$rule.PropagationFlags -ne 'None'){return $false}
 }
 $true
}

function Read-Phase12BConfig {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PrivateConfig)
 if(-not(Test-Path -LiteralPath $PrivateConfig -PathType Leaf)){throw "Private configuration not found: $PrivateConfig"};$yq=Get-Command yq -ErrorAction SilentlyContinue;if($null -eq $yq){throw 'Required prerequisite not found: yq (mikefarah/yq v4).'};$version=(& $yq.Source --version 2>$null|Out-String).Trim();if(-not(Test-Phase12BYqV4Version $version)){throw "Unsupported yq version: $version"}
 function Y([string]$file,[string]$query,[bool]$required=$true){$v=(& $yq.Source -r $query $file 2>$null|Out-String).Trim();if($required -and([string]::IsNullOrWhiteSpace($v)-or $v -eq 'null')){throw "Missing configuration value: $query"};if($v -eq 'null'){$v=''};$v}
 if((Y $PrivateConfig '.schema_version') -ne '1'){throw 'Unsupported environment schema_version.'};$hostFile=Y $PrivateConfig '.host.config';if(-not[IO.Path]::IsPathRooted($hostFile)){$hostFile=Join-Path (Split-Path -Parent $PrivateConfig) $hostFile};if(-not(Test-Path -LiteralPath $hostFile -PathType Leaf)){throw "Host configuration not found: $hostFile"};if((Y $hostFile '.schema_version') -ne '1'){throw 'Unsupported host schema_version.'}
 $h=[ordered]@{};foreach($n in 'host_id','platform'){$h[$n]=Y $hostFile ".${n}"};if($h.host_id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$'){throw 'Host ID is invalid.'};foreach($n in 'execution_root','runner_root','runtime_root','profile_root'){$h[$n]=Y $hostFile ".paths.${n}";if(-not[IO.Path]::IsPathRooted($h[$n])){throw "Host path must be absolute: $n"}};$h.runner_mode=Y $hostFile '.runner.mode';$h.service_identity=Y $hostFile '.runner.service_identity';$h.service_sid=Y $hostFile '.runner.service_sid';$h.serialization=Y $hostFile '.execution.serialization';$h.quiescence_timeout_seconds=Y $hostFile '.execution.quiescence_timeout_seconds' $false;if(-not $h.quiescence_timeout_seconds){$h.quiescence_timeout_seconds=600};if([string]$h.quiescence_timeout_seconds -notmatch '^[1-9][0-9]*$'){throw 'Invalid host quiescence timeout.'};$h.runner_package_path=Y $hostFile '.runner.package_path' $false;if(-not $h.runner_package_path){$h.runner_package_path=Join-Path $h.runtime_root 'packages\actions-runner-win-x64.zip'};if(-not[IO.Path]::IsPathRooted($h.runner_package_path)){throw 'Runner package path must be absolute.'};$h.labels=@((& $yq.Source -r '.runner.labels[]' $hostFile 2>$null)|ForEach-Object{$_.Trim()}|Where-Object{$_});$requiredLabels=@('self-hosted','Windows','X64','codex-automation');if($h.platform -ne 'windows' -or $h.runner_mode -ne 'windows-service' -or $h.service_identity -ne 'network-service' -or $h.service_sid -ne 'S-1-5-20' -or $h.serialization -ne 'global-mutex' -or @(Compare-Object ($requiredLabels|Sort-Object) ($h.labels|Sort-Object -Unique)).Count -ne 0){throw 'Host desired state violates the Phase 12B policy.'}
 $e=[ordered]@{github_owner_id=Y $PrivateConfig '.github.owner_id';project_id=Y $PrivateConfig '.google_cloud.project_id';provider_resource=Y $PrivateConfig '.google_cloud.workload_identity_provider_resource';automation_repository=Y $PrivateConfig '.automation.repository';automation_workflow_path=Y $PrivateConfig '.automation.workflow_path';active_workflow_sha=Y $PrivateConfig '.automation.active_workflow_sha'};if($e.github_owner_id -notmatch '^[1-9][0-9]*$' -or $e.project_id -notmatch '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' -or $e.provider_resource -notmatch '^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$' -or $e.automation_repository -notmatch '^[^/]+/[^/]+$' -or $e.automation_workflow_path -notmatch '^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$' -or $e.active_workflow_sha -notmatch '^[0-9a-f]{40}$'){throw 'Environment desired state is invalid.'}
 $configRoot=Split-Path -Parent $PrivateConfig
 $callerDir=Join-Path $configRoot 'callers';$callers=@();if(Test-Path -LiteralPath $callerDir -PathType Container){foreach($f in Get-ChildItem -LiteralPath $callerDir -Filter '*.yaml' -File){$callers += [pscustomobject]@{Name=$f.BaseName;Path=$f.FullName;Repository=Y $f.FullName '.repository.full_name';RepositoryId=Y $f.FullName '.repository.id';SecretId=Y $f.FullName '.secret.id';WorkflowPath=Y $f.FullName '.workflow.path';Enabled=Y $f.FullName '.runner.enabled';Scope=Y $f.FullName '.runner.scope'}}};if($callers.Count -eq 0){throw 'No caller desired state found.'};foreach($c in $callers){if($c.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $c.Repository -notmatch '^[^/]+/[^/]+$' -or $c.RepositoryId -notmatch '^[1-9][0-9]*$' -or $c.SecretId -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,254}$' -or $c.WorkflowPath -notmatch '^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$' -or $c.Enabled -ne 'true' -or $c.Scope -ne 'repository'){throw "Invalid caller desired state: $($c.Path)"}}
 $migrationFile=Join-Path $configRoot ("migrations\{0}.yaml" -f $h.host_id);$migration=$null
 if(Test-Path -LiteralPath $migrationFile){
  $migrationItem=Get-Item -LiteralPath $migrationFile -Force -ErrorAction Stop
  if(-not(Test-Path -LiteralPath $migrationFile -PathType Leaf) -or -not[string]::IsNullOrWhiteSpace([string]$migrationItem.LinkType) -or -not[string]::IsNullOrWhiteSpace([string]$migrationItem.Target)){throw 'Migration desired-state path is unsafe.'}
  $migration=[pscustomobject]@{Path=[IO.Path]::GetFullPath($migrationFile);SchemaVersion=Y $migrationFile '.schema_version';HostId=Y $migrationFile '.host_id';MigrationType=Y $migrationFile '.migration_type';SourceCaller=Y $migrationFile '.source.caller';SourceRunnerDirectory=Y $migrationFile '.source.runner_directory';PackageVersion=Y $migrationFile '.package.version';PackageSha256=Y $migrationFile '.package.sha256'}
  if($migration.SchemaVersion -cne '1' -or $migration.HostId -cne $h.host_id -or $migration.MigrationType -cne 'phase10-interactive' -or $migration.SourceCaller -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or -not[IO.Path]::IsPathRooted($migration.SourceRunnerDirectory) -or $migration.PackageVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $migration.PackageSha256 -notmatch '^[0-9a-f]{64}$'){throw 'Migration desired state is invalid.'}
  if(@($callers|Where-Object{$_.Name -ceq $migration.SourceCaller}).Count -ne 1){throw 'Migration source caller is missing or ambiguous.'}
 }
 [pscustomobject]@{Environment=$PrivateConfig;HostFile=$hostFile;Host=$h;EnvironmentData=[pscustomobject]$e;Callers=$callers;MigrationFile=if($migration){$migration.Path}else{$migrationFile};Migration=$migration}
}

function Get-Phase12BExternalCallerState {
 [CmdletBinding()]param([Parameter(Mandatory=$true)]$Config,[Parameter(Mandatory=$true)]$Caller,[switch]$TestMode,[string]$FixtureRoot,[string]$ExternalReadbackFile)
 Test-Phase12BTestAdapter -TestMode:$TestMode -FixtureRoot $FixtureRoot -ExternalReadbackFile $ExternalReadbackFile
 if($ExternalReadbackFile){return Get-Content -LiteralPath $ExternalReadbackFile -Raw|ConvertFrom-Json}
 $gh=Get-Command gh -ErrorAction Stop;$gcloud=Get-Command gcloud -ErrorAction Stop
 function Read-Json([scriptblock]$Call,[string]$Name) { $raw=& $Call; if($LASTEXITCODE -ne 0){throw "$Name command failed."}; try{$raw|ConvertFrom-Json -ErrorAction Stop}catch{throw "$Name did not return valid JSON."} }
 try {
   $repo=Read-Json { & $gh.Source api "repos/$($Caller.Repository)" } 'GitHub repository metadata'
   $branch=[string]$repo.default_branch;if([string]::IsNullOrWhiteSpace($branch) -or $branch -notmatch '^[A-Za-z0-9._/-]+$'){throw 'GitHub default branch metadata is invalid.'}
   $runnerListing=Get-Phase12BGitHubRunnerList -Repository $Caller.Repository -GhPath $gh.Source
   $workflow=Read-Json { & $gh.Source api ("repos/{0}/contents/{1}?ref={2}" -f $Caller.Repository,$Caller.WorkflowPath,[uri]::EscapeDataString($branch)) } 'GitHub caller workflow'
   $versions=Read-Json { & $gcloud.Source secrets versions list $Caller.SecretId --project=$Config.EnvironmentData.project_id --format=json } 'Secret metadata'
   $iam=Read-Json { & $gcloud.Source secrets get-iam-policy $Caller.SecretId --project=$Config.EnvironmentData.project_id --format=json } 'Secret IAM metadata'
   $p=$Config.EnvironmentData.provider_resource -split '/';if($p.Count -ne 8){throw 'Invalid WIF Provider resource path.'}
   $provider=Read-Json { & $gcloud.Source iam workload-identity-pools providers describe $p[7] --project=$Config.EnvironmentData.project_id --location=global --workload-identity-pool=$p[5] --format=json } 'WIF Provider metadata'
   [pscustomobject]@{RepositoryId=[string]$repo.id;DefaultBranch=$branch;WorkflowBranch=$branch;Runners=@($runnerListing.Runners);SecretVersions=@($versions);Iam=$iam;Provider=$provider;WorkflowContent=[string]$workflow.content}
 } catch { throw "External metadata read-back failed: $($_.Exception.Message)" }
}
function Test-Phase12BExternalCallerState {
 [CmdletBinding()]param([Parameter(Mandatory=$true)]$Config,[Parameter(Mandatory=$true)]$Caller,[Parameter(Mandatory=$true)]$External,[Parameter(Mandatory=$true)][string]$RunnerName)
 $labels=@($Config.Host.labels|Sort-Object -Unique)
 $allRunners=if($null -ne $External.Runners){@($External.Runners)}else{@()}
 $runner=@($allRunners|Where-Object{$null -ne $_ -and $_.PSObject.Properties['name'] -and [string]$_.name -eq $RunnerName})
 $actualLabels=if($runner.Count -eq 1 -and $null -ne $runner[0].labels){@($runner[0].labels|ForEach-Object{if($_ -and $_.PSObject.Properties['name']){[string]$_.name}}|Where-Object{$_}|Sort-Object -Unique)}else{@()}
 $repoOk=[string]$External.RepositoryId -eq [string]$Caller.RepositoryId
 $branchOk=(-not [string]::IsNullOrWhiteSpace([string]$External.DefaultBranch)) -and ([string]$External.DefaultBranch -ceq [string]$External.WorkflowBranch)
 $runnerOk=$runner.Count -eq 1 -and @(Compare-Object $labels $actualLabels).Count -eq 0
 $allVersions=if($null -ne $External.SecretVersions){@($External.SecretVersions)}else{@()}
 $enabled=@($allVersions|Where-Object{$null -ne $_ -and $_.PSObject.Properties['state'] -and [string]$_.state -ceq 'ENABLED'})
 $secretOk=$null -ne $External.SecretVersions -and $enabled.Count -eq 1 -and $enabled[0].PSObject.Properties['name'] -and [string]$enabled[0].name -match '/versions/[1-9][0-9]*$'
 $providerParts=[string]$Config.EnvironmentData.provider_resource -split '/'
 $expectedMember=if($providerParts.Count -eq 8){"principalSet://iam.googleapis.com/projects/$($providerParts[1])/locations/global/workloadIdentityPools/$($providerParts[5])/attribute.repository_id/$($Caller.RepositoryId)"}else{''}
 $iamOk=$false
 if($External.Iam -and $External.Iam.PSObject.Properties['bindings'] -and $expectedMember){
  $iamOk=$true
  foreach($role in @('roles/secretmanager.secretAccessor','roles/secretmanager.secretVersionManager')){
   $bindings=@($External.Iam.bindings|Where-Object{$_ -and [string]$_.role -ceq $role})
   if($bindings.Count -ne 1){$iamOk=$false;break}
   $members=@($bindings[0].members|ForEach-Object{[string]$_}|Sort-Object -Unique)
   if($members.Count -ne 1 -or $members[0] -cne $expectedMember){$iamOk=$false;break}
  }
 }
 try { $raw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$External.WorkflowContent -replace '\s',''))) } catch { $raw='' }
 $templatePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\templates\caller\codex-connectivity-test.yml.tpl'))
 $expectedWorkflow=''
 if(Test-Path -LiteralPath $templatePath -PathType Leaf){
  $expectedWorkflow=[IO.File]::ReadAllText($templatePath)
  $replacements=[ordered]@{'__AUTOMATION_REPOSITORY__'=[string]$Config.EnvironmentData.automation_repository;'__AUTOMATION_WORKFLOW_PATH__'=[string]$Config.EnvironmentData.automation_workflow_path;'__AUTOMATION_WORKFLOW_SHA__'=[string]$Config.EnvironmentData.active_workflow_sha;'__GOOGLE_CLOUD_PROJECT_ID__'=[string]$Config.EnvironmentData.project_id;'__WORKLOAD_IDENTITY_PROVIDER__'=[string]$Config.EnvironmentData.provider_resource;'__CODEX_AUTH_SECRET_ID__'=[string]$Caller.SecretId}
  foreach($placeholder in $replacements.Keys){$expectedWorkflow=$expectedWorkflow.Replace($placeholder,$replacements[$placeholder])}
 }
 $workflowOk=$branchOk -and $expectedWorkflow -and (($raw -replace "`r`n","`n") -ceq ($expectedWorkflow -replace "`r`n","`n"))
 $cond=if($null -ne $External.Provider -and $External.Provider.PSObject.Properties['attributeCondition']){[string]$External.Provider.attributeCondition}else{''}
 $workflowIdentity="$($Config.EnvironmentData.automation_repository)/$($Config.EnvironmentData.automation_workflow_path)@$($Config.EnvironmentData.active_workflow_sha)"
 $wifOk=$cond -match[regex]::Escape([string]$Config.EnvironmentData.github_owner_id) -and $cond -match[regex]::Escape($workflowIdentity)
 [pscustomobject]@{Repository=if($repoOk){'PASS'}else{'FAIL'};Branch=if($branchOk){'PASS'}else{'FAIL'};Runner=if($runnerOk){'PASS'}else{'FAIL'};Secret=if($secretOk){'PASS'}else{'FAIL'};Iam=if($iamOk){'PASS'}else{'FAIL'};Workflow=if($workflowOk){'PASS'}else{'FAIL'};Wif=if($wifOk){'PASS'}else{'FAIL'};All=($repoOk -and $branchOk -and $runnerOk -and $secretOk -and $iamOk -and $workflowOk -and $wifOk)}
}

function Invoke-Phase12BAction {
 param([Parameter(Mandatory=$true)][string]$Name,[string]$Argument,[switch]$TestMode,[string]$FixtureRoot,[string]$AdapterLog,[string]$ServiceName,[string]$Repository,[string]$RepositoryId,[string]$RuntimeJson,[string]$RunnerPackagePath)
 Test-Phase12BTestAdapter -TestMode:$TestMode -FixtureRoot $FixtureRoot -AdapterLog $AdapterLog
 if($AdapterLog){
   # Hermetic test double: it materializes only harmless files under the
   # test-only temporary root, so later checks exercise actual filesystem
   # state rather than accepting a log entry as evidence.
   Add-Content -LiteralPath $AdapterLog -Value ("ACTION={0};ARG={1};SERVICE={2};REPOSITORY={3}" -f $Name,$Argument,$ServiceName,$Repository)
    switch($Name){
      'EnsureDirectory'{New-Item -ItemType Directory -Path $Argument -Force|Out-Null}
      'WriteRuntime'{if([string]::IsNullOrWhiteSpace($RuntimeJson)){throw 'Test runtime metadata is missing.'};New-Item -ItemType Directory -Path (Split-Path -Parent $Argument) -Force|Out-Null;Set-Content -LiteralPath $Argument -Value $RuntimeJson -NoNewline}
      'EnsureExecutionArea'{& (Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1') -Action ensure -Root $Argument|Out-Null}
      'ApplyAcl'{}
      default{throw "Legacy runner action is unreachable; use Invoke-Phase12BCallerRunner: $Name"}
   }
   return
 }
  switch($Name){'EnsureDirectory'{New-Item -ItemType Directory -Path $Argument -Force|Out-Null}'WriteRuntime'{if([string]::IsNullOrWhiteSpace($RuntimeJson)){throw 'Runtime metadata is missing.'};New-Item -ItemType Directory -Path (Split-Path -Parent $Argument) -Force|Out-Null;Set-Content -LiteralPath $Argument -Value $RuntimeJson -NoNewline}'EnsureExecutionArea'{& (Join-Path $PSScriptRoot '..\self-hosted\managed-execution-area.ps1') -Action ensure -Root $Argument|Out-Null}'ApplyAcl'{if(-not(Test-Path -LiteralPath $Argument)){throw "ACL target missing: $Argument"};& icacls.exe $Argument /inheritance:r /grant:r 'NT AUTHORITY\NETWORK SERVICE:(OI)(CI)(F)' 'BUILTIN\Administrators:(OI)(CI)(F)' 'NT AUTHORITY\SYSTEM:(OI)(CI)(F)'|Out-Null}default{throw "Legacy runner action is unreachable; use Invoke-Phase12BCallerRunner: $Name"}}
}
function Test-Phase12BQuiescent { [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ExecutionRoot);$current=Join-Path $ExecutionRoot 'state\current-run.json';if(Test-Path -LiteralPath $current){return $false};$workspaces=Join-Path $ExecutionRoot 'workspaces';if(Test-Path -LiteralPath $workspaces){return (@(Get-ChildItem -LiteralPath $workspaces -Force -ErrorAction Stop).Count -eq 0)};return $true }
$script:Phase12BCallerLifecycleStates = @(
    'ABSENT','REGISTERING','REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','ACTIVE',
    'RETIRING','DISPATCH_DISABLED','SERVICE_STOPPED','RUNNER_REMOVED','RETIRED'
)

function Assert-Phase12BRepositoryIdentity {
    param([Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RepositoryId)
    if ($RepositoryFullName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository full name.' }
    if ($RepositoryId -notmatch '^[1-9][0-9]*$') { throw 'Invalid immutable repository ID.' }
}

function Get-Phase12BCallerRunnerIdentity {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunnerRoot,[Parameter(Mandatory)][string]$RepositoryId)
    if (-not [IO.Path]::IsPathRooted($RunnerRoot)) { throw 'Runner root must be absolute.' }
    if ($RepositoryId -notmatch '^[1-9][0-9]*$') { throw 'Invalid immutable repository ID.' }
    $runnerDirectory = [IO.Path]::GetFullPath((Join-Path $RunnerRoot "repo-$RepositoryId"))
    [pscustomobject]@{
        RepositoryId=$RepositoryId
        RunnerDirectory=$runnerDirectory
        RunnerName="codex-repo-$RepositoryId"
        ServiceName=Get-Phase12BExpectedServiceName $runnerDirectory
    }
}

function Get-Phase12BRunnerMetadataPath {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$RepositoryId,
        [ValidateSet('active','retired')][string]$State='active'
    )
    if (-not [IO.Path]::IsPathRooted($RuntimeRoot)) { throw 'Runtime root must be absolute.' }
    if ($RepositoryId -notmatch '^[1-9][0-9]*$') { throw 'Invalid immutable repository ID.' }
    [IO.Path]::GetFullPath((Join-Path $RuntimeRoot (Join-Path "runners\$State" "$RepositoryId.json")))
}

function Test-Phase12BMetadataIdentity {
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryFullName,
        [Parameter(Mandatory)][string]$RunnerRoot
    )
    $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $RunnerRoot -RepositoryId $RepositoryId
    $required=@('schema','repository_id','repository_full_name','runner_directory','runner_name','service_name','lifecycle_state','state_entered_at')
    foreach($name in $required) { if(-not $Metadata.PSObject.Properties[$name]) { throw "Runtime metadata is missing $name." } }
    if([string]$Metadata.schema -ne '1') { throw 'Runtime metadata schema is unsupported.' }
    if([string]$Metadata.repository_id -cne $RepositoryId) { throw 'Runtime metadata immutable repository identity conflicts with desired state.' }
    if([string]$Metadata.repository_full_name -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Runtime metadata repository display name is invalid.' }
    if([IO.Path]::GetFullPath([string]$Metadata.runner_directory) -cne $identity.RunnerDirectory -or [string]$Metadata.runner_name -cne $identity.RunnerName) { throw 'Runtime metadata runner identity conflicts with canonical identity.' }
    $metadataServiceName=[string]$Metadata.service_name
    if($metadataServiceName -and $metadataServiceName -notmatch '^actions\.runner\.[A-Za-z0-9_.-]+$'){throw 'Runtime metadata service name is invalid.'}
    if([string]$Metadata.lifecycle_state -notin $script:Phase12BCallerLifecycleStates) { throw 'Runtime metadata lifecycle state is unsupported.' }
    $timestamp=[DateTimeOffset]::MinValue
    $timestampValue=$Metadata.state_entered_at
    if($timestampValue -is [DateTime]){
        $dateTime=[DateTime]$timestampValue
        if($dateTime.Kind -eq [DateTimeKind]::Unspecified){throw 'Runtime metadata state_entered_at has no timezone.'}
        $timestamp=[DateTimeOffset]::new($dateTime.ToUniversalTime())
    } elseif($timestampValue -is [DateTimeOffset]) {
        $timestamp=[DateTimeOffset]$timestampValue
    } else {
        $timestampText=[string]$timestampValue
        if($timestampText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$' -or -not [DateTimeOffset]::TryParse($timestampText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)){throw 'Runtime metadata state_entered_at is not ISO-8601 UTC.'}
    }
    if($timestamp.Offset -ne [TimeSpan]::Zero){throw 'Runtime metadata state_entered_at is not UTC.'}
    $true
}

function Read-Phase12BRunnerMetadata {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RunnerRoot,
        [ValidateSet('active','retired')][string]$State='active'
    )
    $path=Get-Phase12BRunnerMetadataPath -RuntimeRoot $RuntimeRoot -RepositoryId $RepositoryId -State $State
    $directory=Split-Path -Parent $path
    if(Test-Path -LiteralPath $directory -PathType Container){if(@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop|Where-Object{$_.Name -like ".$RepositoryId.*.tmp" -or $_.Name -like ".$RepositoryId.*.bak"}).Count -ne 0){throw 'Runtime metadata temporary residue requires recovery.'}}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if(-not(Test-Phase12BNoReparse $path)) { throw 'Runtime metadata path is unsafe.' }
    try {
        $raw=Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $timestampMatches=[regex]::Matches($raw,'"state_entered_at"\s*:\s*"(?<value>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00))"')
        if($timestampMatches.Count -ne 1){throw 'timestamp encoding'}
        $metadata=$raw | ConvertFrom-Json -ErrorAction Stop
        $metadata.state_entered_at=$timestampMatches[0].Groups['value'].Value
    } catch { throw 'Runtime metadata is malformed.' }
    Test-Phase12BMetadataIdentity -Metadata $metadata -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $RunnerRoot | Out-Null
    if(($State -eq 'retired') -ne ([string]$metadata.lifecycle_state -eq 'RETIRED')){throw 'Runtime metadata namespace conflicts with lifecycle state.'}
    $metadata
}

function Write-Phase12BRunnerMetadata {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RunnerRoot,
        [Parameter(Mandatory)][ValidateSet('ABSENT','REGISTERING','REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','ACTIVE','RETIRING','DISPATCH_DISABLED','SERVICE_STOPPED','RUNNER_REMOVED','RETIRED')][string]$LifecycleState,
        [AllowEmptyString()][string]$ServiceName,
        [ValidateSet('active','retired')][string]$State='active'
    )
    Assert-Phase12BRepositoryIdentity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
    $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $RunnerRoot -RepositoryId $RepositoryId
    $path=Get-Phase12BRunnerMetadataPath -RuntimeRoot $RuntimeRoot -RepositoryId $RepositoryId -State $State
    $directory=Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    if(-not(Test-Phase12BNoReparse $directory)) { throw 'Runtime metadata directory is unsafe.' }
    if(@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop|Where-Object{$_.Name -like ".$RepositoryId.*.tmp" -or $_.Name -like ".$RepositoryId.*.bak"}).Count -ne 0) { throw 'Runtime metadata temporary residue requires recovery.' }
    if(-not $PSBoundParameters.ContainsKey('ServiceName')){$ServiceName=Get-Phase12BExpectedServiceName $identity.RunnerDirectory}
    if($ServiceName -and $ServiceName -notmatch '^actions\.runner\.[A-Za-z0-9_.-]+$'){throw 'Refusing to persist an invalid service name.'}
    $metadata=[ordered]@{
        schema=1; repository_id=$RepositoryId; repository_full_name=$RepositoryFullName
        runner_directory=$identity.RunnerDirectory; runner_name=$identity.RunnerName; service_name=$ServiceName
        lifecycle_state=$LifecycleState; state_entered_at=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
    }
    $temporary=Join-Path $directory (".$RepositoryId.$([guid]::NewGuid().ToString('N')).tmp")
    $backup=Join-Path $directory (".$RepositoryId.$([guid]::NewGuid().ToString('N')).bak")
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($metadata|ConvertTo-Json -Compress))
        $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::Replace($temporary,$path,$backup,$true);Remove-Item -LiteralPath $backup -Force}else{[IO.File]::Move($temporary,$path)}
    } finally { if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force };if(Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force } }
    [pscustomobject]$metadata
}

function Get-Phase12BCallerRunnerClassification {
    [CmdletBinding()]param([Parameter(Mandatory)]$Observation)
    $metadata=$Observation.Metadata
    $lifecycle=if($null -ne $metadata){[string]$metadata.lifecycle_state}else{'ABSENT'}
    $present=@([bool]$Observation.LocalPresent,[bool]$Observation.GitHubPresent,[bool]$Observation.ServicePresent)
    $anyPresent=$present -contains $true
    $allPresent=@($present | Where-Object { -not $_ }).Count -eq 0
    $conflict=[bool]$Observation.DuplicateRunner -or [bool]$Observation.DuplicateService -or [bool]$Observation.IdentityConflict -or [bool]$Observation.RepositoryIdMismatch -or [bool]$Observation.PathConflict -or [bool]$Observation.LabelConflict -or [bool]$Observation.ServiceIdentityConflict
    if($conflict) { return [pscustomobject]@{Snapshot='CONFLICT';Lifecycle=$lifecycle;Recovery='MANUAL_INTERVENTION_REQUIRED';ReconstructRuntimeMetadata=$false} }
    if($null -eq $metadata -and -not $anyPresent) { return [pscustomobject]@{Snapshot='NEW';Lifecycle='ABSENT';Recovery='RETRY_SAFE';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false} }
    if($null -eq $metadata) {
        if($allPresent -and [bool]$Observation.ExactMatch) { return [pscustomobject]@{Snapshot='PARTIAL';Lifecycle='ABSENT';Recovery='RECOVER_WITH_APPROVAL';ReconstructRuntimeMetadata=$true;ReconcileRepositoryName=$false} }
        return [pscustomobject]@{Snapshot='CONFLICT';Lifecycle='ABSENT';Recovery='MANUAL_INTERVENTION_REQUIRED';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false}
    }
    $serviceStopped=[bool]$Observation.ServicePresent -and [string]$Observation.Service.State -eq 'Stopped'
    $runnerAndServiceExact=[bool]$Observation.LocalPresent -and [bool]$Observation.RunnerExact -and [bool]$Observation.ServiceExact
    $registeringTopology=(-not $anyPresent) -or ([bool]$Observation.LocalPresent -and -not [bool]$Observation.ServicePresent -and ((-not [bool]$Observation.GitHubPresent) -or [bool]$Observation.RunnerExact)) -or ($allPresent -and $runnerAndServiceExact)
    $serviceStoppedOrRemovalInProgress=($runnerAndServiceExact -and $serviceStopped) -or ([bool]$Observation.LocalPresent -and -not [bool]$Observation.GitHubPresent -and -not [bool]$Observation.ServicePresent) -or (-not $anyPresent)
    $topologyMatches=switch($lifecycle){
        'ACTIVE' { $allPresent -and [bool]$Observation.ExactMatch }
        'REGISTERING' { $registeringTopology }
        'REGISTERED' { [bool]$Observation.LocalPresent -and [bool]$Observation.RunnerExact -and -not [bool]$Observation.ServicePresent }
        'SERVICE_INSTALLING' { [bool]$Observation.LocalPresent -and [bool]$Observation.RunnerExact -and ((-not [bool]$Observation.ServicePresent) -or [bool]$Observation.ServiceExact) }
        'SERVICE_INSTALLED' { $allPresent -and $runnerAndServiceExact }
        'RETIRING' { $allPresent -and $runnerAndServiceExact }
        'DISPATCH_DISABLED' { $allPresent -and $runnerAndServiceExact }
        'SERVICE_STOPPED' { $serviceStoppedOrRemovalInProgress }
        'RUNNER_REMOVED' { -not $anyPresent }
        'RETIRED' { -not $anyPresent }
        default { $false }
    }
    if(-not $topologyMatches){return [pscustomobject]@{Snapshot='CONFLICT';Lifecycle=$lifecycle;Recovery='MANUAL_INTERVENTION_REQUIRED';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false}}
    if($Observation.PSObject.Properties['MetadataRetirementOverlap'] -and [bool]$Observation.MetadataRetirementOverlap){return [pscustomobject]@{Snapshot='PARTIAL';Lifecycle='RETIRED';Recovery='RESUME_SAFE';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false}}
    if([bool]$Observation.RepositoryNameDrift){return [pscustomobject]@{Snapshot='PARTIAL';Lifecycle=$lifecycle;Recovery='RECOVER_WITH_APPROVAL';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$true}}
    if($lifecycle -in @('ACTIVE','RETIRED')) { return [pscustomobject]@{Snapshot='CONSISTENT';Lifecycle=$lifecycle;Recovery='RETRY_SAFE';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false} }
    if($lifecycle -in @('REGISTERING','REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED','RETIRING','DISPATCH_DISABLED','SERVICE_STOPPED','RUNNER_REMOVED')) { return [pscustomobject]@{Snapshot='PARTIAL';Lifecycle=$lifecycle;Recovery='RESUME_SAFE';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false} }
    [pscustomobject]@{Snapshot='CONFLICT';Lifecycle=$lifecycle;Recovery='MANUAL_INTERVENTION_REQUIRED';ReconstructRuntimeMetadata=$false;ReconcileRepositoryName=$false}
}

function Read-Phase12BHostConfig {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$HostConfig)
    if(-not(Test-Path -LiteralPath $HostConfig -PathType Leaf) -or -not(Test-Phase12BNoReparse $HostConfig)) { throw 'HostConfig is missing or unsafe.' }
    $yq=Get-Command yq -ErrorAction Stop
    if(-not(Test-Phase12BYqV4Version ((& $yq.Source --version 2>$null|Out-String).Trim()))) { throw 'yq v4 is required.' }
    function ReadValue([string]$query,[bool]$required=$true) {
        $value=(& $yq.Source -r $query $HostConfig 2>$null|Out-String).Trim()
        if($required -and ([string]::IsNullOrWhiteSpace($value) -or $value -eq 'null')) { throw "HostConfig missing $query" }
        if($value -eq 'null') { return '' }; $value
    }
    if((ReadValue '.schema_version') -ne '1' -or (ReadValue '.platform') -ne 'windows' -or (ReadValue '.runner.mode') -ne 'windows-service' -or (ReadValue '.runner.service_identity') -ne 'network-service' -or (ReadValue '.runner.service_sid') -ne 'S-1-5-20') { throw 'HostConfig violates the Windows runner policy.' }
    $config=[ordered]@{
        HostId=ReadValue '.host_id'; RunnerRoot=ReadValue '.paths.runner_root'; RuntimeRoot=ReadValue '.paths.runtime_root'
        ExecutionRoot=ReadValue '.paths.execution_root'; ProfileRoot=ReadValue '.paths.profile_root'
        RunnerPackagePath=ReadValue '.runner.package_path' $false
        Labels=@((& $yq.Source -r '.runner.labels[]' $HostConfig 2>$null)|ForEach-Object{$_.Trim()}|Where-Object{$_})
        QuiescenceTimeoutSeconds=ReadValue '.execution.quiescence_timeout_seconds' $false
    }
    foreach($name in @('RunnerRoot','RuntimeRoot','ExecutionRoot','ProfileRoot')) { if(-not [IO.Path]::IsPathRooted($config[$name])) { throw "Host path must be absolute: $name" } }
    if(-not $config.RunnerPackagePath){$config.RunnerPackagePath=Join-Path $config.RuntimeRoot 'packages\actions-runner-win-x64.zip'}
    if(-not [IO.Path]::IsPathRooted($config.RunnerPackagePath)) { throw 'Host runner package path must be absolute.' }
    $expectedLabels=@('self-hosted','Windows','X64','codex-automation')
    if(@(Compare-Object ($expectedLabels|Sort-Object) ($config.Labels|Sort-Object -Unique)).Count -ne 0) { throw 'Host runner labels violate Phase 12B policy.' }
    if([string]::IsNullOrWhiteSpace($config.QuiescenceTimeoutSeconds)) { $config.QuiescenceTimeoutSeconds=600 }
    elseif([string]$config.QuiescenceTimeoutSeconds -notmatch '^[1-9][0-9]*$') { throw 'execution.quiescence_timeout_seconds must be a positive integer.' }
    [pscustomobject]$config
}

function Assert-Phase12BFixtureRoot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
    if(-not(Test-Path -LiteralPath $FixtureRoot -PathType Container)) { throw 'TestMode requires an existing FixtureRoot.' }
    $item=Get-Item -LiteralPath $FixtureRoot -Force
    $full=[IO.Path]::GetFullPath($item.FullName);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'FixtureRoot must be a non-reparse system temporary directory.' }
    $full
}

function Read-Phase12BCallerRunnerFixture {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
    $root=Assert-Phase12BFixtureRoot $FixtureRoot
    $path=Join-Path $root 'caller-runner-fixture.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or -not(Test-Phase12BNoReparse $path)) { throw 'Caller runner fixture is missing or unsafe.' }
    try { $fixture=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Caller runner fixture is malformed.' }
    if([string]$fixture.schema -ne '1') { throw 'Caller runner fixture schema is unsupported.' }
    $fixture
}

function Write-Phase12BCallerRunnerFixture {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)]$Fixture)
    $root=Assert-Phase12BFixtureRoot $FixtureRoot;$path=Join-Path $root 'caller-runner-fixture.json';$temporary=Join-Path $root ('.caller-runner.'+[guid]::NewGuid().ToString('N')+'.tmp')
    try { [IO.File]::WriteAllText($temporary,($Fixture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $path -Force } finally { if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force} }
}

function Get-Phase12BQuiescenceDecision {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][ValidateSet('FREE','BUSY','ABANDONED','UNKNOWN')][string]$MutexState,
        [Parameter(Mandatory)][ValidateSet('ABSENT','VALID','MALFORMED')][string]$CurrentRunState,
        [string]$CurrentRepositoryId,[Parameter(Mandatory)][string]$TargetRepositoryId,
        [int]$ActiveGitHubJobCount=0,[int]$TargetResidualCount=0,[switch]$ResidualOwnershipUnknown,
        [switch]$SharedResidualPresent,[switch]$SharedResidualConsistentWithOtherCaller
    )
    if($ActiveGitHubJobCount -lt 0 -or $TargetResidualCount -lt 0){throw 'Quiescence counts must not be negative.'}
    if($ActiveGitHubJobCount -gt 0){return [pscustomobject]@{Decision='WAIT';Reason='TARGET_GITHUB_JOB_ACTIVE'}}
    if($TargetResidualCount -gt 0){return [pscustomobject]@{Decision='WAIT';Reason='TARGET_RESIDUAL_STATE'}}
    if($ResidualOwnershipUnknown){return [pscustomobject]@{Decision='WAIT';Reason='RESIDUAL_OWNERSHIP_UNKNOWN'}}
    if($MutexState -eq 'ABANDONED'){return [pscustomobject]@{Decision='WAIT';Reason='ABANDONED_MUTEX'}}
    if($CurrentRunState -eq 'MALFORMED'){return [pscustomobject]@{Decision='WAIT';Reason='EXECUTION_OWNERSHIP_UNKNOWN'}}
    if($CurrentRunState -eq 'VALID'){
        if($CurrentRepositoryId -eq $TargetRepositoryId){return [pscustomobject]@{Decision='WAIT';Reason='TARGET_CALLER_EXECUTION'}}
        if($SharedResidualPresent -and -not $SharedResidualConsistentWithOtherCaller){return [pscustomobject]@{Decision='WAIT';Reason='SHARED_RESIDUAL_OWNERSHIP_UNKNOWN'}}
        if($MutexState -eq 'BUSY'){return [pscustomobject]@{Decision='PASS';Reason='OTHER_CALLER_EXECUTION'}}
        return [pscustomobject]@{Decision='WAIT';Reason='EXECUTION_OWNERSHIP_INCONSISTENT'}
    }
    if($SharedResidualPresent){return [pscustomobject]@{Decision='WAIT';Reason='SHARED_RESIDUAL_OWNERSHIP_UNKNOWN'}}
    if($MutexState -eq 'FREE'){return [pscustomobject]@{Decision='PASS';Reason='NO_CURRENT_EXECUTION'}}
    [pscustomobject]@{Decision='WAIT';Reason='MUTEX_OWNERSHIP_UNKNOWN'}
}

function Get-Phase12BExecutionMutexState {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ExecutionRoot)
    $markerPath=Join-Path $ExecutionRoot '.codex-automation-managed'
    try{
        if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf) -or -not(Test-Phase12BNoReparse $markerPath)){return 'UNKNOWN'}
        $marker=Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        $id=[string]$marker.execution_area_id
        if($id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'){return 'UNKNOWN'}
        $name="Global\CodexAutomation-ExecutionArea-$($id -replace '-','')"
        try{$mutex=[Threading.Mutex]::OpenExisting($name)} catch [Threading.WaitHandleCannotBeOpenedException] {return 'FREE'} catch {return 'UNKNOWN'}
        try{
            $acquired=$false;$abandoned=$false
            try{$acquired=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$acquired=$true;$abandoned=$true}
            if($acquired){$mutex.ReleaseMutex();if($abandoned){return 'ABANDONED'};return 'FREE'}
            return 'BUSY'
        } finally {$mutex.Dispose()}
    } catch { return 'UNKNOWN' }
}

function Read-Phase12BCurrentRunState {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path)){return [pscustomobject]@{State='ABSENT';RepositoryId=''}}
    try{
        if(-not(Test-Path -LiteralPath $Path -PathType Leaf) -or -not(Test-Phase12BNoReparse $Path)){throw 'unsafe current-run'}
        $raw=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $timestampMatches=[regex]::Matches($raw,'"started_at_utc"\s*:\s*"(?<value>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z)"')
        if($timestampMatches.Count -ne 1){throw 'timestamp encoding'}
        $current=$raw|ConvertFrom-Json -ErrorAction Stop
        $current.started_at_utc=$timestampMatches[0].Groups['value'].Value
        $expected=@('execution_id','github_run_attempt','github_run_id','repository_id','schema','started_at_utc')
        $actual=@($current.PSObject.Properties.Name|Sort-Object)
        if(@(Compare-Object $expected $actual).Count -ne 0){throw 'fields are not exact'}
        if(($current.schema -isnot [int]) -and ($current.schema -isnot [long])){throw 'schema type'}
        if([int64]$current.schema -ne 1){throw 'schema value'}
        if([string]$current.execution_id -notmatch '^[A-Za-z0-9._-]{1,200}$'){throw 'execution id'}
        foreach($name in @('repository_id','github_run_id','github_run_attempt')){
            $value=$current.$name
            if(($value -isnot [string]) -or [string]$value -notmatch '^[1-9][0-9]*$'){throw "$name type or value"}
        }
        $timestamp=[DateTimeOffset]::MinValue;$timestampText=[string]$current.started_at_utc
        if(($current.started_at_utc -isnot [string]) -or $timestampText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$' -or -not [DateTimeOffset]::TryParse($timestampText,[Globalization.CultureInfo]::InvariantCulture,([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),[ref]$timestamp) -or $timestamp.Offset -ne [TimeSpan]::Zero){throw 'timestamp'}
        [pscustomobject]@{State='VALID';RepositoryId=[string]$current.repository_id;ExecutionId=[string]$current.execution_id}
    } catch {[pscustomobject]@{State='MALFORMED';RepositoryId=''}}
}

function Get-Phase12BGitHubActiveJobCount {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RepositoryFullName)
    if($RepositoryFullName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'Invalid repository full name for quiescence read-back.'}
    $gh=Get-Command gh -ErrorAction Stop;$total=0
    foreach($status in @('queued','in_progress')){
        try{$raw=& $gh.Source api --method GET "repos/$RepositoryFullName/actions/runs" -f status=$status -f per_page=1 2>$null;if($LASTEXITCODE -ne 0){throw 'query failed'};$response=$raw|ConvertFrom-Json -ErrorAction Stop;$count=[int]$response.total_count;if($count -lt 0){throw 'negative count'};$total+=$count}catch{throw "GitHub quiescence read-back failed for $status."}
    }
    $total
}

function Get-Phase12BResidualState {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ExecutionRoot,[Parameter(Mandatory)][string]$RepositoryFullName)
    $targetCount=0;$unknown=$false;$sharedResidualPresent=$false
    $otherWorkspaceNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $workspaceRoot=Join-Path $ExecutionRoot 'workspaces'
    if(Test-Path -LiteralPath $workspaceRoot -PathType Container){
        foreach($entry in @(Get-ChildItem -LiteralPath $workspaceRoot -Force -ErrorAction Stop)){
            if(-not $entry.PSIsContainer -or -not(Test-Phase12BNoReparse $entry.FullName)){$unknown=$true;continue}
            $markerPath=Join-Path $entry.FullName '.codex-workspace-owned.json'
            try{if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf) -or -not(Test-Phase12BNoReparse $markerPath)){throw 'unsafe marker'};$marker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json -ErrorAction Stop;if([string]$marker.repository -eq $RepositoryFullName){$targetCount++}elseif([string]$marker.repository -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){[void]$otherWorkspaceNames.Add($entry.Name)}else{$unknown=$true}}catch{$unknown=$true}
        }
    }
    $sharedConsistent=$true
    $tempPath=Join-Path $ExecutionRoot 'temp'
    if(Test-Path -LiteralPath $tempPath -PathType Container){if(@(Get-ChildItem -LiteralPath $tempPath -Force -ErrorAction Stop).Count -gt 0){$sharedResidualPresent=$true;$sharedConsistent=$false}}
    $codexHomePath=Join-Path $ExecutionRoot 'codex-home'
    if(Test-Path -LiteralPath $codexHomePath -PathType Container){
        foreach($entry in @(Get-ChildItem -LiteralPath $codexHomePath -Force -ErrorAction Stop)){
            $sharedResidualPresent=$true
            if(-not $entry.PSIsContainer -or -not(Test-Phase12BNoReparse $entry.FullName) -or -not $otherWorkspaceNames.Contains($entry.Name)){$sharedConsistent=$false}
        }
    }
    [pscustomobject]@{TargetCount=$targetCount;OwnershipUnknown=$unknown;SharedResidualPresent=$sharedResidualPresent;SharedResidualConsistentWithOtherCaller=($sharedResidualPresent -and $sharedConsistent)}
}

function Wait-Phase12BCallerQuiescence {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$ExecutionRoot,[Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryFullName,[int]$TimeoutSeconds=600,
        [switch]$TestMode,[ValidateSet('FREE','BUSY','ABANDONED','UNKNOWN')][string]$TestMutexState='FREE',
        [int]$TestActiveGitHubJobCount=0,[int]$TestTargetResidualCount=0,[switch]$TestResidualOwnershipUnknown,
        [switch]$TestSharedResidualPresent,[switch]$TestSharedResidualConsistentWithOtherCaller
    )
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$currentPath=Join-Path $ExecutionRoot 'state\current-run.json';$lastReason='UNKNOWN'
    while($true){
        $current=Read-Phase12BCurrentRunState -Path $currentPath;$currentState=$current.State;$currentRepositoryId=$current.RepositoryId
        if($TestMode){$mutexState=$TestMutexState;$activeJobs=$TestActiveGitHubJobCount;$residual=[pscustomobject]@{TargetCount=$TestTargetResidualCount;OwnershipUnknown=[bool]$TestResidualOwnershipUnknown;SharedResidualPresent=[bool]$TestSharedResidualPresent;SharedResidualConsistentWithOtherCaller=[bool]$TestSharedResidualConsistentWithOtherCaller}}
        else{$mutexState=Get-Phase12BExecutionMutexState -ExecutionRoot $ExecutionRoot;$activeJobs=Get-Phase12BGitHubActiveJobCount -RepositoryFullName $RepositoryFullName;$residual=Get-Phase12BResidualState -ExecutionRoot $ExecutionRoot -RepositoryFullName $RepositoryFullName}
        $decision=Get-Phase12BQuiescenceDecision -MutexState $mutexState -CurrentRunState $currentState -CurrentRepositoryId $currentRepositoryId -TargetRepositoryId $RepositoryId -ActiveGitHubJobCount $activeJobs -TargetResidualCount $residual.TargetCount -ResidualOwnershipUnknown:$residual.OwnershipUnknown -SharedResidualPresent:$residual.SharedResidualPresent -SharedResidualConsistentWithOtherCaller:$residual.SharedResidualConsistentWithOtherCaller
        if($decision.Decision -eq 'PASS'){return [pscustomobject]@{Result='PASS';Reason=$decision.Reason}}
        $lastReason=$decision.Reason
        if([DateTime]::UtcNow -ge $deadline){return [pscustomobject]@{Result='STOP';Reason='QUIESCENCE_TIMEOUT';Detail=$lastReason;Recovery='RETRY_SAFE'}}
        Start-Sleep -Milliseconds $(if($TestMode){100}else{2000})
    }
}

function Get-Phase12BFixedRunnerAdapterArguments {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][ValidateSet('InstallPackage','Register','InstallService','StartService','StopService','Unregister','RemoveService','MigrateRunner','Verify')][string]$Action,
        [Parameter(Mandatory)]$Host,[Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RepositoryId
    )
    Assert-Phase12BRepositoryIdentity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
    $arguments=@{Action=$Action;RunnerRoot=$Identity.RunnerDirectory;Repository=$RepositoryFullName;RepositoryId=$RepositoryId;ServiceName=$Identity.ServiceName;ServiceIdentity=$script:Phase12BServiceIdentity}
    if($Action -eq 'InstallPackage'){
        if([string]::IsNullOrWhiteSpace([string]$Host.HostId) -or [string]::IsNullOrWhiteSpace([string]$Host.RunnerRoot) -or [string]::IsNullOrWhiteSpace([string]$Host.RunnerPackagePath)){throw 'Fresh onboarding package authority is incomplete.'}
        $canonical=Get-Phase12BCallerRunnerIdentity -RunnerRoot ([string]$Host.RunnerRoot) -RepositoryId $RepositoryId
        if([IO.Path]::GetFullPath([string]$Identity.RunnerDirectory) -ine [IO.Path]::GetFullPath([string]$canonical.RunnerDirectory)){throw 'Fresh onboarding target runner directory contradicts host desired state.'}
        $arguments.RunnerPackagePath=[string]$Host.RunnerPackagePath
        $arguments.HostRunnerRoot=[string]$Host.RunnerRoot
        $arguments.OperationId=Get-Phase12BOnboardPackageOperationId -HostId ([string]$Host.HostId) -RepositoryId $RepositoryId
    }
    $arguments
}

function Invoke-Phase12BFixedRunnerAdapter {
    param([Parameter(Mandatory)][string]$Action,[Parameter(Mandatory)]$Host,[Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RepositoryId)
    $adapter=Join-Path $PSScriptRoot 'runner-adapter.ps1'
    $arguments=Get-Phase12BFixedRunnerAdapterArguments -Action $Action -Host $Host -Identity $Identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
    & $adapter @arguments | Out-Null
}

function Invoke-Phase12BInstallPackage {
    [CmdletBinding()]param(
        [Parameter(Mandatory)]$Host,[Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RepositoryId,
        [switch]$TestMode
    )
    $arguments=Get-Phase12BFixedRunnerAdapterArguments -Action InstallPackage -Host $Host -Identity $Identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
    if($TestMode){
        # TestMode substitutes only the external ACL mutation provider. The
        # package contract, staging, validation, and atomic publication remain
        # the same production primitives and arguments.
        return Install-Phase12BRunnerPackageAtomically -RunnerRoot $arguments.HostRunnerRoot -TargetRunnerDirectory $arguments.RunnerRoot -OperationId $arguments.OperationId -PackagePath $arguments.RunnerPackagePath -ApplyAcl {}
    }
    Invoke-Phase12BFixedRunnerAdapter -Action InstallPackage -Host $Host -Identity $Identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
    [pscustomobject]@{State='PUBLISHED'}
}

function Get-Phase12BCallerRunnerObservation {
    [CmdletBinding()]param(
        [Parameter(Mandatory)]$Host,[Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RepositoryId,
        [switch]$TestMode,[string]$FixtureRoot
    )
    Assert-Phase12BRepositoryIdentity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
    $identity=Get-Phase12BCallerRunnerIdentity -RunnerRoot $Host.RunnerRoot -RepositoryId $RepositoryId
    $metadata=Read-Phase12BRunnerMetadata -RuntimeRoot $Host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $Host.RunnerRoot
    $retiredMetadata=Read-Phase12BRunnerMetadata -RuntimeRoot $Host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $Host.RunnerRoot -State retired
    $metadataRetirementOverlap=$false
    if($null -ne $metadata -and $null -ne $retiredMetadata){
        if([string]$metadata.lifecycle_state -ne 'RUNNER_REMOVED' -or [string]$retiredMetadata.lifecycle_state -ne 'RETIRED'){throw 'Active and retired runtime metadata conflict.'}
        $metadataRetirementOverlap=$true;$metadata=$retiredMetadata
    }
    if($null -eq $metadata){$metadata=$retiredMetadata}
    if($TestMode) {
        $fixture=Read-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot
        $actualRepositoryId=[string]$fixture.repository_id
        $actualRepositoryFullName=if($fixture.PSObject.Properties['repository_full_name']){[string]$fixture.repository_full_name}else{$RepositoryFullName}
        $localPresent=[bool]$fixture.local_present
        $runnerRecords=@($fixture.runners)
        $serviceRecords=@($fixture.services)
    } else {
        $injectionNames=@('PHASE12B_TEST_MODE','PHASE12B_TEST_ROOT','PHASE12B_TEST_ADAPTER','PHASE12B_RUNNER_STATE','PHASE12B_SERVICE_STATE','PHASE12B_RUNNER_APPLY','PHASE12B_SERVICE_APPLY','PHASE12B_SERVICE_STOP','PHASE12B_RUNNER_UNREGISTER','PHASE12B_WORKFLOW_APPLY','PHASE12B_WORKFLOW_REMOVE','PHASE12B_VERIFY','CODEX_RUNNER_TOKEN_COMMAND','CODEX_RUNNER_PACKAGE_PATH')
        foreach($name in $injectionNames){if(-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))){throw "Production test/command injection is prohibited: $name"}}
        $gh=Get-Command gh -ErrorAction Stop
        try { $repoRaw=& $gh.Source api "repos/$RepositoryFullName" 2>$null;if($LASTEXITCODE -ne 0){throw 'repository query failed'};$repo=$repoRaw|ConvertFrom-Json -ErrorAction Stop } catch { throw "GitHub repository read-back failed: $($_.Exception.Message)" }
        $actualRepositoryId=[string]$repo.id
        $actualRepositoryFullName=[string]$repo.full_name
        try { $runnerResponse=Get-Phase12BGitHubRunnerList -Repository $RepositoryFullName -GhPath $gh.Source;$runnerRecords=@($runnerResponse.Runners) } catch { throw "GitHub runner read-back failed: $($_.Exception.Message)" }
        $localPresent=Test-Path -LiteralPath $identity.RunnerDirectory -PathType Container
        try { $serviceRecords=@(Get-CimInstance Win32_Service -ErrorAction Stop) } catch { throw "Windows Service read-back failed: $($_.Exception.Message)" }
        $fixture=$null
    }
    $metadataServiceName=if($metadata){[string]$metadata.service_name}else{''}
    $officialServiceName=Get-Phase12BExpectedServiceName $identity.RunnerDirectory
    $expectedServiceName=if($metadataServiceName){$metadataServiceName}else{$officialServiceName}
    $identity=[pscustomobject]@{RepositoryId=$RepositoryId;RunnerDirectory=$identity.RunnerDirectory;RunnerName=$identity.RunnerName;ServiceName=$expectedServiceName}
    $matchingRunners=@($runnerRecords|Where-Object{$_ -and $_.PSObject.Properties['name'] -and [string]$_.name -ceq $identity.RunnerName})
    $actualLabels=if($matchingRunners.Count -eq 1){@($matchingRunners[0].labels|ForEach-Object{if($_ -is [string]){$_}elseif($_.PSObject.Properties['name']){[string]$_.name}}|Where-Object{$_}|Sort-Object -Unique)}else{@()}
    $expectedLabels=@($Host.Labels|Sort-Object -Unique)
    $namedServices=@(if($expectedServiceName){$serviceRecords|Where-Object{$_ -and $_.PSObject.Properties['Name'] -and [string]$_.Name -ieq $expectedServiceName}})
    $pathServices=@($serviceRecords|Where-Object{$_ -and $_.PSObject.Properties['PathName'] -and (Test-Phase12BServicePath ([string]$_.PathName) $identity.RunnerDirectory)})
    $service=$null;if($namedServices.Count -eq 1){$service=$namedServices[0]}
    $servicePathExact=$null -ne $service -and (Test-Phase12BServicePath ([string]$service.PathName) $identity.RunnerDirectory)
    $serviceIdentityExact=$null -ne $service -and [string]$service.StartName -in @('NT AUTHORITY\NETWORK SERVICE','NT AUTHORITY\NetworkService')
    $githubPresent=$matchingRunners.Count -gt 0;$servicePresent=$namedServices.Count -gt 0
    $duplicateRunner=$matchingRunners.Count -ne [Math]::Min(1,$matchingRunners.Count)
    $duplicateService=$namedServices.Count -gt 1 -or $pathServices.Count -gt 1 -or ($pathServices.Count -eq 1 -and (-not $expectedServiceName -or [string]$pathServices[0].Name -ine $expectedServiceName)) -or ($metadataServiceName -and $officialServiceName -and $metadataServiceName -ine $officialServiceName)
    $repositoryMismatch=-not [string]::IsNullOrWhiteSpace($actualRepositoryId) -and $actualRepositoryId -cne $RepositoryId
    $labelConflict=$githubPresent -and @(Compare-Object $expectedLabels $actualLabels).Count -ne 0
    $pathConflict=$servicePresent -and -not $servicePathExact
    $serviceIdentityConflict=$servicePresent -and -not $serviceIdentityExact
    $serviceStateConflict=$servicePresent -and [string]$service.State -notin @('Running','Stopped')
    $serviceRunning=$servicePresent -and [string]$service.State -eq 'Running'
    $identityConflict=(((-not $TestMode) -and $localPresent -and -not(Test-Phase12BNoReparse $identity.RunnerDirectory)) -or $serviceStateConflict)
    $runnerExact=$matchingRunners.Count -eq 1 -and -not($repositoryMismatch -or $labelConflict -or $duplicateRunner)
    $serviceExact=$namedServices.Count -eq 1 -and $servicePathExact -and $serviceIdentityExact -and -not($duplicateService -or $identityConflict)
    $exact=$localPresent -and $runnerExact -and $serviceExact -and $serviceRunning
    [pscustomobject]@{
        Metadata=$metadata;LocalPresent=$localPresent;GitHubPresent=$githubPresent;ServicePresent=$servicePresent;ExactMatch=$exact;RunnerExact=$runnerExact;ServiceExact=$serviceExact
        DuplicateRunner=$duplicateRunner;DuplicateService=$duplicateService;IdentityConflict=$identityConflict;RepositoryIdMismatch=$repositoryMismatch
        PathConflict=$pathConflict;LabelConflict=$labelConflict;ServiceIdentityConflict=$serviceIdentityConflict
        ActualRepositoryId=$actualRepositoryId;ActualRepositoryFullName=$actualRepositoryFullName;RepositoryNameDrift=($actualRepositoryId -eq $RepositoryId -and $actualRepositoryFullName -cne $RepositoryFullName -or ($metadata -and [string]$metadata.repository_full_name -cne $RepositoryFullName));MetadataRetirementOverlap=$metadataRetirementOverlap;Identity=$identity;Service=$service;Fixture=$fixture
    }
}

function Invoke-Phase12BFixtureStartServiceProvider {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string]$ExpectedServiceName
    )
    $fixture=Read-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot
    $behavior=if($fixture.PSObject.Properties['start_service_behavior']){[string]$fixture.start_service_behavior}else{'SUCCESS'}
    if($behavior -notin @('SUCCESS','ERROR','NO_STATE_CHANGE')){throw 'Fixture StartService behavior is unsupported.'}
    $callCount=if($fixture.PSObject.Properties['start_service_call_count']){[int]$fixture.start_service_call_count}else{0}
    $fixture|Add-Member -NotePropertyName start_service_call_count -NotePropertyValue ($callCount+1) -Force
    if($behavior -eq 'ERROR'){
        Write-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot -Fixture $fixture
        throw 'Fixture StartService provider failed.'
    }
    if($behavior -eq 'SUCCESS'){
        $services=@($fixture.services|Where-Object{$_ -and $_.PSObject.Properties['Name'] -and [string]$_.Name -ieq $ExpectedServiceName})
        if($services.Count -ne 1){throw 'Fixture StartService provider requires one exact Service.'}
        $services[0]|Add-Member -NotePropertyName State -NotePropertyValue 'Running' -Force
    }
    Write-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot -Fixture $fixture
}

function Invoke-Phase12BServiceInstalledToActive {
    [CmdletBinding()]param(
        [Parameter(Mandatory)]$Host,
        [Parameter(Mandatory)][string]$RepositoryFullName,
        [Parameter(Mandatory)][string]$RepositoryId,
        [switch]$TestMode,[string]$FixtureRoot
    )
    $before=Get-Phase12BCallerRunnerObservation -Host $Host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot
    if($null -eq $before.Metadata -or [string]$before.Metadata.lifecycle_state -ne 'SERVICE_INSTALLED'){throw 'ACTIVE transition requires SERVICE_INSTALLED lifecycle metadata.'}
    if(-not($before.LocalPresent -and $before.RunnerExact -and $before.ServicePresent -and $before.ServiceExact)){throw 'SERVICE_INSTALLED topology is not exact.'}
    $serviceState=[string]$before.Service.State
    if($serviceState -eq 'Stopped'){
        if($TestMode){Invoke-Phase12BFixtureStartServiceProvider -FixtureRoot $FixtureRoot -ExpectedServiceName $before.Identity.ServiceName}
        else{Invoke-Phase12BFixedRunnerAdapter -Action StartService -Host $Host -Identity $before.Identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId}
    } elseif($serviceState -ne 'Running') { throw 'SERVICE_INSTALLED Service state is not resumable.' }
    $after=Get-Phase12BCallerRunnerObservation -Host $Host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot
    if(-not($after.LocalPresent -and $after.RunnerExact -and $after.ServicePresent -and $after.ServiceExact -and [string]$after.Service.State -eq 'Running' -and $after.ExactMatch)){throw 'Service start/read-back did not reach exact Running topology.'}
    $metadata=Write-Phase12BRunnerMetadata -RuntimeRoot $Host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $Host.RunnerRoot -LifecycleState ACTIVE -ServiceName $after.Identity.ServiceName
    [pscustomobject]@{Observation=$after;Metadata=$metadata}
}

function Invoke-Phase12BCallerRunner {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][ValidateSet('Inspect','Onboard','Offboard','Verify')][string]$Action,
        [Parameter(Mandatory)][string]$HostConfig,[Parameter(Mandatory)][string]$RepositoryFullName,[Parameter(Mandatory)][string]$RepositoryId,
        [switch]$BeginRetirement,[switch]$FinalizeRetirement,[switch]$TestMode,[string]$FixtureRoot
    )
    $validatedFixtureRoot=$null
    if($TestMode){$validatedFixtureRoot=Assert-Phase12BFixtureRoot $FixtureRoot}elseif($FixtureRoot){throw 'FixtureRoot is test-only.'}
    $host=Read-Phase12BHostConfig -HostConfig $HostConfig
    if(($BeginRetirement -or $FinalizeRetirement) -and $Action -ne 'Offboard'){throw 'Retirement phase switches are valid only with Offboard.'}
    if($BeginRetirement -and $FinalizeRetirement){throw 'BeginRetirement and FinalizeRetirement are mutually exclusive.'}
    if($TestMode){
        $prefix=$validatedFixtureRoot.TrimEnd('\')+'\'
        foreach($path in @($host.RunnerRoot,$host.RuntimeRoot,$host.ExecutionRoot,$host.ProfileRoot)){if(-not [IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'TestMode HostConfig paths must remain beneath FixtureRoot.'}}
    }
    $observation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId -TestMode:$TestMode -FixtureRoot $FixtureRoot
    $classification=Get-Phase12BCallerRunnerClassification -Observation $observation
    $hostState=Get-Phase12BHostState -RuntimeRoot $host.RuntimeRoot -ExecutionRoot $host.ExecutionRoot -HostId $host.HostId -ProfileRoot $host.ProfileRoot -RunnerRoot $host.RunnerRoot
    if($Action -eq 'Inspect') {
        return [pscustomobject]@{Action=$Action;Result='PASS';RepositoryId=$RepositoryId;HostState=$hostState;Snapshot=$classification.Snapshot;LifecycleBefore=$classification.Lifecycle;LifecycleAfter=$classification.Lifecycle;Recovery=$classification.Recovery;Identity=$observation.Identity;ServiceState=if($observation.Service){[string]$observation.Service.State}else{'ABSENT'};StateEnteredAt=if($observation.Metadata){[string]$observation.Metadata.state_entered_at}else{''};Mutations='NONE';Postcondition='READ_ONLY_SNAPSHOT';ReconstructRuntimeMetadata=$classification.ReconstructRuntimeMetadata;NextAction='NONE'}
    }
    if($Action -eq 'Verify') {
        if($hostState -ne 'EXISTING'){throw "Host state is not mutation/verification safe: $hostState"}
        if($classification.Snapshot -ne 'CONSISTENT'){throw "Caller runner verification failed: $($classification.Snapshot)/$($classification.Recovery)"}
        return [pscustomobject]@{Action=$Action;Result='PASS';RepositoryId=$RepositoryId;HostState=$hostState;Snapshot=$classification.Snapshot;LifecycleBefore=$classification.Lifecycle;LifecycleAfter=$classification.Lifecycle;Recovery=$classification.Recovery;Identity=$observation.Identity;ServiceState=if($observation.Service){[string]$observation.Service.State}else{'ABSENT'};StateEnteredAt=[string]$observation.Metadata.state_entered_at;Mutations='NONE';Postcondition='EXACT_ACTIVE_OR_RETIRED_TOPOLOGY';ReconstructRuntimeMetadata=$false;NextAction='NONE'}
    }
    if($hostState -ne 'EXISTING'){throw "Host state is not mutation safe: $hostState"}
    if($BeginRetirement){
        if($classification.Recovery -eq 'MANUAL_INTERVENTION_REQUIRED'){throw 'Caller runner state is contradictory; automatic mutation is prohibited.'}
        $before=$classification.Lifecycle
        if($before -eq 'ACTIVE' -and ($classification.Snapshot -eq 'CONSISTENT' -or $classification.ReconcileRepositoryName)){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RETIRING -ServiceName $observation.Identity.ServiceName|Out-Null;$after='RETIRING'}
        elseif($before -eq 'RETIRING' -and $classification.Recovery -eq 'RESUME_SAFE'){$after='RETIRING'}
        else{throw 'BeginRetirement requires exact ACTIVE or resumable RETIRING topology.'}
        $metadata=Read-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot
        return [pscustomobject]@{Action=$Action;Result='PASS';RepositoryId=$RepositoryId;HostState=$hostState;Snapshot=$classification.Snapshot;LifecycleBefore=$before;LifecycleAfter=$after;Recovery=$classification.Recovery;Identity=$observation.Identity;ServiceState=if($observation.Service){[string]$observation.Service.State}else{'ABSENT'};StateEnteredAt=[string]$metadata.state_entered_at;Mutations=if($TestMode){'TEST_FIXTURE_METADATA_ONLY'}else{'APPROVED_PRODUCTION_METADATA_ONLY'};Postcondition='RETIRING_FIXED_BEFORE_WORKFLOW_MUTATION';ReconstructRuntimeMetadata=$false;NextAction='RETIRE_WORKFLOW_AND_READ_BACK'}
    }
    if(-not $TestMode) {
        if($classification.Recovery -eq 'MANUAL_INTERVENTION_REQUIRED'){throw 'Caller runner state is contradictory; automatic mutation is prohibited.'}
        $before=$classification.Lifecycle;$identity=$observation.Identity
        if($Action -eq 'Onboard'){
            $resumeState=if($before -eq 'RETIRED'){'ABSENT'}else{$before}
            if($classification.Snapshot -eq 'CONSISTENT' -and $before -eq 'ACTIVE'){$after='ACTIVE'}
            elseif($classification.ReconcileRepositoryName -and $before -eq 'ACTIVE'){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState $before -ServiceName $observation.Identity.ServiceName|Out-Null;$after=$before}
            elseif($classification.ReconstructRuntimeMetadata){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState ACTIVE -ServiceName $observation.Identity.ServiceName|Out-Null;$after='ACTIVE'}
            else {
                if($resumeState -in @('ABSENT','REGISTERING')){
                    if($before -eq 'RETIRED'){$retired=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -State retired;if(Test-Path -LiteralPath $retired){Remove-Item -LiteralPath $retired -Force}}
                    Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState REGISTERING -ServiceName ''|Out-Null
                    Invoke-Phase12BInstallPackage -Host $host -Identity $identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId | Out-Null
                    $resumeState='REGISTERING'
                }
                if($resumeState -in @('REGISTERING','REGISTERED','SERVICE_INSTALLING','SERVICE_INSTALLED')){
                    if($resumeState -ne 'SERVICE_INSTALLED'){
                        $observation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                        if(-not($observation.RunnerExact -and $observation.ServiceExact)){
                            Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState REGISTERING -ServiceName ''|Out-Null
                            if($observation.GitHubPresent){Invoke-Phase12BFixedRunnerAdapter -Action Unregister -Host $host -Identity $identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId;$observation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId}
                            if($observation.GitHubPresent -or $observation.ServicePresent){throw 'REGISTERING cleanup did not reach a safe pre-registration topology.'}
                            Invoke-Phase12BFixedRunnerAdapter -Action Register -Host $host -Identity $identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                            $observation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                            if(-not($observation.LocalPresent -and $observation.RunnerExact -and $observation.ServiceExact)){throw 'Official runner/service registration postcondition failed.'}
                        }
                        Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState SERVICE_INSTALLING -ServiceName $observation.Identity.ServiceName|Out-Null
                    }
                    $observation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                    if(-not($observation.LocalPresent -and $observation.RunnerExact -and $observation.ServiceExact)){throw 'Official runner/service registration postcondition failed.'}
                    Invoke-Phase12BFixedRunnerAdapter -Action InstallService -Host $host -Identity $observation.Identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                    Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState SERVICE_INSTALLED -ServiceName $observation.Identity.ServiceName|Out-Null
                    $resumeState='SERVICE_INSTALLED'
                }
                $transition=Invoke-Phase12BServiceInstalledToActive -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                $observation=$transition.Observation
                $retired=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -State retired;if(Test-Path -LiteralPath $retired){Remove-Item -LiteralPath $retired -Force};$after='ACTIVE'
            }
        } else {
            if($before -eq 'RETIRED' -and $classification.Recovery -in @('RETRY_SAFE','RESUME_SAFE')){$active=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId;if(Test-Path -LiteralPath $active){Remove-Item -LiteralPath $active -Force};$after='RETIRED'}
            else {
                if($before -notin @('ACTIVE','RETIRING','DISPATCH_DISABLED','SERVICE_STOPPED','RUNNER_REMOVED')){throw 'Offboard requires ACTIVE or resumable retiring metadata.'}
                $resumeState=$before
                if($resumeState -eq 'SERVICE_STOPPED' -and $observation.ServicePresent -and [string]$observation.Service.State -ne 'Stopped'){throw 'SERVICE_STOPPED metadata contradicts actual Windows Service state.'}
                if($resumeState -eq 'RUNNER_REMOVED' -and ($observation.LocalPresent -or $observation.GitHubPresent -or $observation.ServicePresent)){throw 'RUNNER_REMOVED metadata contradicts actual runner/service state.'}
                if($resumeState -eq 'ACTIVE'){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RETIRING -ServiceName $observation.Identity.ServiceName|Out-Null;$resumeState='RETIRING'}
                # The caller lifecycle owner removes and reads back the workflow before invoking this host action.
                if($resumeState -eq 'RETIRING'){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState DISPATCH_DISABLED -ServiceName $observation.Identity.ServiceName|Out-Null;$resumeState='DISPATCH_DISABLED'}
                if($resumeState -eq 'DISPATCH_DISABLED'){
                    $quiet=Wait-Phase12BCallerQuiescence -ExecutionRoot $host.ExecutionRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -TimeoutSeconds ([int]$host.QuiescenceTimeoutSeconds)
                    if($quiet.Result -ne 'PASS'){throw "$($quiet.Reason); RECOVERY_DECISION=$($quiet.Recovery)"}
                    if($observation.ServicePresent){Invoke-Phase12BFixedRunnerAdapter -Action StopService -Host $host -Identity $identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId}
                    $observation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                    if($observation.ServicePresent -and [string]$observation.Service.State -ne 'Stopped'){throw 'Windows Service stop postcondition failed.'}
                    Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState SERVICE_STOPPED -ServiceName $observation.Identity.ServiceName|Out-Null;$resumeState='SERVICE_STOPPED'
                }
                if($resumeState -eq 'SERVICE_STOPPED'){
                    if($observation.GitHubPresent){Invoke-Phase12BFixedRunnerAdapter -Action Unregister -Host $host -Identity $identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId}
                    if($observation.ServicePresent){Invoke-Phase12BFixedRunnerAdapter -Action RemoveService -Host $host -Identity $identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId}
                    if(Test-Path -LiteralPath $identity.RunnerDirectory -PathType Container){
                        $expectedParent=[IO.Path]::GetFullPath($host.RunnerRoot).TrimEnd('\')+'\';$target=[IO.Path]::GetFullPath($identity.RunnerDirectory)
                        if(-not $target.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -cne "repo-$RepositoryId"){throw 'Canonical runner removal target is unsafe.'}
                        Remove-Item -LiteralPath $target -Recurse -Force
                    }
                    $afterObservation=Get-Phase12BCallerRunnerObservation -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId
                    if($afterObservation.LocalPresent -or $afterObservation.GitHubPresent -or $afterObservation.ServicePresent){throw 'Runner/service absence postcondition failed.'}
                    Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RUNNER_REMOVED -ServiceName $identity.ServiceName|Out-Null;$resumeState='RUNNER_REMOVED'
                }
                if($FinalizeRetirement){
                    if($resumeState -ne 'RUNNER_REMOVED'){throw 'Final retirement requires exact RUNNER_REMOVED topology.'}
                    Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RETIRED -State retired -ServiceName $identity.ServiceName|Out-Null
                    $active=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId;if(Test-Path -LiteralPath $active){Remove-Item -LiteralPath $active -Force};$after='RETIRED'
                } else {$after='RUNNER_REMOVED'}
            }
        }
        $finalMetadata=if($after -eq 'RETIRED'){Read-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -State retired}else{Read-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot}
        return [pscustomobject]@{Action=$Action;Result='PASS';RepositoryId=$RepositoryId;HostState=$hostState;Snapshot=$classification.Snapshot;LifecycleBefore=$before;LifecycleAfter=$after;Recovery=$classification.Recovery;Identity=$identity;ServiceState='READ_BACK';StateEnteredAt=[string]$finalMetadata.state_entered_at;Mutations='APPROVED_PRODUCTION';Postcondition=if($after -eq 'RUNNER_REMOVED'){'RUNNER_AND_SERVICE_ABSENT_AWAITING_CLOUD_RETIREMENT'}else{'EXACT_LIFECYCLE_TOPOLOGY'};ReconstructRuntimeMetadata=$classification.ReconstructRuntimeMetadata;NextAction=if($after -eq 'RUNNER_REMOVED'){'FINALIZE_CLOUD_AND_DESIRED_STATE'}else{'VERIFY'}}
    }
    if($classification.Recovery -eq 'MANUAL_INTERVENTION_REQUIRED'){throw 'Caller runner state is contradictory; automatic mutation is prohibited.'}
    $fixture=$observation.Fixture;$before=$classification.Lifecycle
    if($Action -eq 'Onboard') {
        if($classification.Snapshot -eq 'CONSISTENT' -and $classification.Lifecycle -eq 'ACTIVE'){$after='ACTIVE'}
        elseif($classification.ReconcileRepositoryName -and $before -eq 'ACTIVE'){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState $before -ServiceName $observation.Identity.ServiceName|Out-Null;$after=$before}
        else {
            if($before -eq 'RETIRED'){$retired=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -State retired;if(Test-Path -LiteralPath $retired){Remove-Item -LiteralPath $retired -Force}}
            $testServiceName="actions.runner.$($RepositoryFullName -replace '/','-').$($observation.Identity.RunnerName)"
            $resumeState=if($before -eq 'RETIRED'){'ABSENT'}else{$before}
            if($resumeState -in @('ABSENT','REGISTERING')){
                Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState REGISTERING -ServiceName ''|Out-Null
                $packageResult=Invoke-Phase12BInstallPackage -Host $host -Identity $observation.Identity -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId -TestMode
                if($packageResult.State -notin @('PUBLISHED','ALREADY_PUBLISHED')){throw "Test package publication did not complete: $($packageResult.State)"}
                $fixture.local_present=$true
                $resumeState='REGISTERING'
            }
            if($resumeState -in @('REGISTERING','REGISTERED','SERVICE_INSTALLING')){$fixture.runners=@([pscustomobject]@{name=$observation.Identity.RunnerName;labels=@($host.Labels|ForEach-Object{[pscustomobject]@{name=$_}})});Set-Content -LiteralPath (Join-Path $observation.Identity.RunnerDirectory '.service') -Value $testServiceName -NoNewline;$fixture.services=@([pscustomobject]@{Name=$testServiceName;PathName=('"{0}"' -f (Join-Path $observation.Identity.RunnerDirectory 'bin\RunnerService.exe'));StartName='NT AUTHORITY\NETWORK SERVICE';State='Running'});Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState SERVICE_INSTALLING -ServiceName $testServiceName|Out-Null;Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState SERVICE_INSTALLED -ServiceName $testServiceName|Out-Null;$resumeState='SERVICE_INSTALLED'}
            Write-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot -Fixture $fixture
            $transition=Invoke-Phase12BServiceInstalledToActive -Host $host -RepositoryFullName $RepositoryFullName -RepositoryId $RepositoryId -TestMode -FixtureRoot $FixtureRoot
            $observation=$transition.Observation;$fixture=$observation.Fixture
            $after='ACTIVE'
        }
    } else {
        if($classification.Lifecycle -eq 'RETIRED' -and $classification.Recovery -in @('RETRY_SAFE','RESUME_SAFE')){$active=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId;if(Test-Path -LiteralPath $active){Remove-Item -LiteralPath $active -Force};$after='RETIRED'}
        else {
            if($classification.Lifecycle -ne 'ACTIVE' -and $classification.Lifecycle -notin @('RETIRING','DISPATCH_DISABLED','SERVICE_STOPPED','RUNNER_REMOVED')){throw 'Offboard requires ACTIVE or resumable retiring metadata.'}
            if($classification.Lifecycle -in @('ACTIVE','RETIRING','DISPATCH_DISABLED')){$testCurrentState=if($fixture.PSObject.Properties['current_run_state']){[string]$fixture.current_run_state}elseif([string]::IsNullOrWhiteSpace([string]$fixture.current_run_repository_id)){'ABSENT'}else{'VALID'};$testDecision=Get-Phase12BQuiescenceDecision -MutexState $(if($fixture.PSObject.Properties['mutex_state']){[string]$fixture.mutex_state}else{'FREE'}) -CurrentRunState $testCurrentState -CurrentRepositoryId ([string]$fixture.current_run_repository_id) -TargetRepositoryId $RepositoryId -ActiveGitHubJobCount $(if($fixture.PSObject.Properties['active_github_job_count']){[int]$fixture.active_github_job_count}else{0}) -TargetResidualCount $(if($fixture.PSObject.Properties['target_residual_count']){[int]$fixture.target_residual_count}else{0}) -ResidualOwnershipUnknown:$(if($fixture.PSObject.Properties['residual_ownership_unknown']){[bool]$fixture.residual_ownership_unknown}else{$false}) -SharedResidualPresent:$(if($fixture.PSObject.Properties['shared_residual_present']){[bool]$fixture.shared_residual_present}else{$false}) -SharedResidualConsistentWithOtherCaller:$(if($fixture.PSObject.Properties['shared_residual_consistent_with_other_caller']){[bool]$fixture.shared_residual_consistent_with_other_caller}else{$false});if($testDecision.Decision -ne 'PASS'){throw "QUIESCENCE_TIMEOUT: $($testDecision.Reason); RECOVERY_DECISION=RETRY_SAFE"}}
            $testServiceName=[string]$observation.Identity.ServiceName;$resumeState=$classification.Lifecycle
            if($resumeState -eq 'ACTIVE'){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RETIRING -ServiceName $testServiceName|Out-Null;$resumeState='RETIRING'}
            if($resumeState -eq 'RETIRING'){Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState DISPATCH_DISABLED -ServiceName $testServiceName|Out-Null;$fixture.workflow_state='ABSENT';$resumeState='DISPATCH_DISABLED'}
            if($resumeState -eq 'DISPATCH_DISABLED'){foreach($service in @($fixture.services)){if($null -ne $service){$service|Add-Member -NotePropertyName State -NotePropertyValue 'Stopped' -Force}};Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState SERVICE_STOPPED -ServiceName $testServiceName|Out-Null;$resumeState='SERVICE_STOPPED'}
            if($resumeState -eq 'SERVICE_STOPPED'){$fixture.services=@();$fixture.runners=@();$fixture.local_present=$false;if(Test-Path -LiteralPath $observation.Identity.RunnerDirectory){Remove-Item -LiteralPath $observation.Identity.RunnerDirectory -Recurse -Force};Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RUNNER_REMOVED -ServiceName $testServiceName|Out-Null;$resumeState='RUNNER_REMOVED'}
            if($FinalizeRetirement){
                Write-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -LifecycleState RETIRED -State retired -ServiceName $testServiceName|Out-Null
                $active=Get-Phase12BRunnerMetadataPath -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId
                if(Test-Path -LiteralPath $active){Remove-Item -LiteralPath $active -Force}
                $after='RETIRED'
            } else {$after='RUNNER_REMOVED'}
        }
    }
    Write-Phase12BCallerRunnerFixture -FixtureRoot $FixtureRoot -Fixture $fixture
    $finalMetadata=if($after -eq 'RETIRED'){Read-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot -State retired}else{Read-Phase12BRunnerMetadata -RuntimeRoot $host.RuntimeRoot -RepositoryId $RepositoryId -RepositoryFullName $RepositoryFullName -RunnerRoot $host.RunnerRoot}
    [pscustomobject]@{Action=$Action;Result='PASS';RepositoryId=$RepositoryId;HostState=$hostState;Snapshot=$classification.Snapshot;LifecycleBefore=$before;LifecycleAfter=$after;Recovery=$classification.Recovery;Identity=$observation.Identity;ServiceState='FIXTURE';StateEnteredAt=[string]$finalMetadata.state_entered_at;Mutations='TEST_FIXTURE_ONLY';Postcondition=if($after -eq 'RUNNER_REMOVED'){'RUNNER_AND_SERVICE_ABSENT_AWAITING_CLOUD_RETIREMENT'}else{'EXACT_LIFECYCLE_TOPOLOGY'};ReconstructRuntimeMetadata=$false;NextAction=if($after -eq 'RUNNER_REMOVED'){'FINALIZE_CLOUD_AND_DESIRED_STATE'}else{'VERIFY'}}
}

$script:Phase12BMigrationStages=@(
    'LEGACY_VERIFIED','DISPATCH_FENCING','DISPATCH_FENCED','QUIESCENT','TARGET_HOST_PREPARED',
    'LEGACY_RUNNER_UNREGISTERING','LEGACY_RUNNER_UNREGISTERED',
    'TARGET_RUNNER_REGISTERING','TARGET_RUNNER_REGISTERED',
    'SERVICE_INSTALLING','SERVICE_INSTALLED','SERVICE_RUNNING',
    'ACTIVE_VERIFIED','DISPATCH_RESTORING','DISPATCH_RESTORED','MIGRATION_COMPLETE'
)
function Get-Phase12BRunnerPackageContract {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Sha256
    )
    if($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Runner package version must be an exact semantic version.'}
    if($Sha256 -notmatch '^[0-9a-f]{64}$'){throw 'Runner package SHA-256 must be 64 lowercase hexadecimal characters.'}
    $archive="actions-runner-win-x64-$Version.zip"
    [pscustomobject]@{
        Version=$Version
        ArchiveName=$archive
        Uri="https://github.com/actions/runner/releases/download/v$Version/$archive"
        ReleaseApiPath="repos/actions/runner/releases/tags/v$Version"
        ExpectedAssetDigest="sha256:$Sha256"
        Sha256=$Sha256
    }
}

function Get-Phase12BOnboardPackageOperationId {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][string]$RepositoryId
    )
    if($HostId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$'){throw 'Invalid host identity for onboarding package operation.'}
    if($RepositoryId -notmatch '^[1-9][0-9]*$'){throw 'Invalid immutable repository ID for onboarding package operation.'}
    $material=[Text.Encoding]::UTF8.GetBytes("phase12b-onboard-package-v1`0$HostId`0$RepositoryId")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=$sha.ComputeHash($material)}finally{$sha.Dispose()}
    $guidBytes=[byte[]]::new(16)
    [Array]::Copy($hash,$guidBytes,16)
    [guid]::new($guidBytes).ToString('D')
}

function Test-Phase12BRunnerPackage {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSha256)
    Test-Phase12BFileSha256 -Path $Path -ExpectedSha256 $ExpectedSha256
}

function Test-Phase12BRunnerReleaseAsset {
    [CmdletBinding()]param([Parameter(Mandatory)]$Contract,[Parameter(Mandatory)]$Release)
    if([string]$Release.tag_name -cne "v$($Contract.Version)" -or $null -eq $Release.PSObject.Properties['assets']){return $false}
    $assets=@($Release.assets|Where-Object{[string]$_.name -ceq [string]$Contract.ArchiveName})
    if($assets.Count -ne 1){return $false}
    $asset=$assets[0]
    [string]$asset.browser_download_url -ceq [string]$Contract.Uri -and
        [string]$asset.digest -ceq [string]$Contract.ExpectedAssetDigest -and
        [string]$asset.state -ceq 'uploaded'
}

function Get-Phase12BCompleteRunnerList {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][scriptblock]$FetchPages,
        [ValidateRange(1,100)][int]$PageSize=100,
        [ValidateRange(1,100)][int]$MaxPages=100
    )
    try{$pages=@(& $FetchPages)}catch{throw 'GitHub runner pagination read-back failed.'}
    if($pages.Count -eq 0 -or $pages.Count -gt $MaxPages){throw 'GitHub runner pagination is incomplete or exceeds the safety limit.'}
    $totalCount=-1
    foreach($page in $pages){
        if($null -eq $page -or $null -eq $page.PSObject.Properties['total_count'] -or $null -eq $page.PSObject.Properties['runners']){throw 'GitHub runner page is malformed.'}
        $parsed=0
        if(-not[int]::TryParse([string]$page.total_count,[ref]$parsed) -or $parsed -lt 0){throw 'GitHub runner total_count is malformed.'}
        if($totalCount -lt 0){$totalCount=$parsed}elseif($totalCount -ne $parsed){throw 'GitHub runner total_count changed during pagination.'}
    }
    $expectedPages=[Math]::Max(1,[int][Math]::Ceiling($totalCount/[double]$PageSize))
    if($expectedPages -gt $MaxPages -or $pages.Count -ne $expectedPages){throw 'GitHub runner page count does not match total_count.'}
    $runners=[Collections.Generic.List[object]]::new()
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for($index=0;$index -lt $pages.Count;$index++){
        $pageRunners=@($pages[$index].runners)
        $expectedCount=if($index -lt ($expectedPages-1)){$PageSize}else{$totalCount-($PageSize*$index)}
        if($pageRunners.Count -ne $expectedCount){throw 'GitHub runner page is truncated or over-complete.'}
        foreach($runner in $pageRunners){
            $id=if($runner -and $runner.PSObject.Properties['id']){[string]$runner.id}else{''}
            $name=if($runner -and $runner.PSObject.Properties['name']){[string]$runner.name}else{''}
            if($id -notmatch '^[1-9][0-9]*$' -or $name -notmatch '^[A-Za-z0-9_.-]+$'){throw 'GitHub runner identity is malformed.'}
            if(-not $ids.Add($id)){throw 'GitHub runner pagination returned a duplicate runner ID.'}
            [void]$runners.Add($runner)
        }
    }
    if($runners.Count -ne $totalCount){throw 'GitHub runner fetched count does not match total_count.'}
    [pscustomobject]@{TotalCount=$totalCount;PageCount=$pages.Count;Runners=$runners.ToArray()}
}

function Get-Phase12BGitHubRunnerList {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$Repository,
        [string]$GhPath
    )
    if($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'Invalid repository identity for runner read-back.'}
    if([string]::IsNullOrWhiteSpace($GhPath)){$GhPath=(Get-Command gh -ErrorAction Stop).Source}
    Get-Phase12BCompleteRunnerList -FetchPages {
        $raw=& $GhPath api --paginate --slurp "repos/$Repository/actions/runners?per_page=100" 2>$null
        if($LASTEXITCODE -ne 0){throw 'GitHub runner pagination failed.'}
        try{@(($raw|Out-String|ConvertFrom-Json -ErrorAction Stop))}catch{throw 'GitHub runner pagination returned malformed JSON.'}
    }
}

function Test-Phase12BRunnerPackageTree {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Root)
    if(-not(Test-Path -LiteralPath $Root -PathType Container) -or -not(Test-Phase12BNoReparse $Root)){return $false}
    foreach($relative in @('config.cmd','run.cmd','bin\Runner.Listener.exe','bin\RunnerService.exe')){
        $path=Join-Path $Root $relative
        if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or -not(Test-Phase12BNoReparse $path)){return $false}
    }
    $true
}

function Assert-Phase12BRunnerStagingAuthority {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RunnerRoot,
        [Parameter(Mandatory)][string]$OperationId
    )
    $operationGuid=[guid]::Empty
    if(-not[guid]::TryParseExact($OperationId,'D',[ref]$operationGuid)){throw 'Migration operation ID is invalid.'}
    if(-not(Test-Path -LiteralPath $RunnerRoot)){return}
    $root=[IO.Path]::GetFullPath($RunnerRoot)
    if(-not(Test-Path -LiteralPath $root -PathType Container) -or -not(Test-Phase12BNoReparse $root)){throw 'Runner root is missing or unsafe.'}
    $stagingRoot=Join-Path $root '.migration-staging'
    if(-not(Test-Path -LiteralPath $stagingRoot)){return}
    if(-not(Test-Path -LiteralPath $stagingRoot -PathType Container) -or -not(Test-Phase12BNoReparse $stagingRoot)){throw 'Runner package staging root is unsafe.'}
    $unexpected=@(Get-ChildItem -LiteralPath $stagingRoot -Force|Where-Object{$_.Name -cne $OperationId})
    if($unexpected.Count -ne 0){throw 'Unknown runner package staging state requires operator review.'}
    $operationRoot=Join-Path $stagingRoot $OperationId
    if(Test-Path -LiteralPath $operationRoot){
        if(-not(Test-Path -LiteralPath $operationRoot -PathType Container) -or -not(Test-Phase12BNoReparse $operationRoot)){throw 'Current migration staging is unsafe.'}
        $entries=@(Get-ChildItem -LiteralPath $operationRoot -Force)
        if(@($entries|Where-Object{$_.Name -cne 'runner'}).Count -ne 0){throw 'Current migration staging contains unknown content.'}
        $stagingRunner=Join-Path $operationRoot 'runner'
        if(Test-Path -LiteralPath $stagingRunner){
            if(-not(Test-Path -LiteralPath $stagingRunner -PathType Container) -or -not(Test-Phase12BNoReparse $stagingRunner)){throw 'Current runner package staging tree is unsafe.'}
        }
    }
}

function Install-Phase12BRunnerPackageAtomically {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RunnerRoot,
        [Parameter(Mandatory)][string]$TargetRunnerDirectory,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$PackagePath,
        [scriptblock]$ApplyAcl
    )
    Assert-Phase12BRunnerStagingAuthority -RunnerRoot $RunnerRoot -OperationId $OperationId
    $root=[IO.Path]::GetFullPath($RunnerRoot);$target=[IO.Path]::GetFullPath($TargetRunnerDirectory)
    if(-not(Test-Path -LiteralPath $root -PathType Container) -or -not(Test-Phase12BNoReparse $root)){throw 'Runner root is missing or unsafe.'}
    if([IO.Path]::GetFullPath((Split-Path -Parent $target)) -ine $root){throw 'Target runner directory must be a direct child of the canonical runner root.'}
    if(-not(Test-Path -LiteralPath $PackagePath -PathType Leaf) -or -not(Test-Phase12BNoReparse $PackagePath)){throw 'Runner package path is missing or unsafe.'}
    $stagingRoot=Join-Path $root '.migration-staging';$operationRoot=Join-Path $stagingRoot $OperationId;$stagingRunner=Join-Path $operationRoot 'runner'
    if(Test-Path -LiteralPath $target){
        if(-not(Test-Phase12BRunnerPackageTree $target)){throw 'Final runner root is partial or unexpected.'}
        if(Test-Path -LiteralPath $operationRoot){
            if(-not(Test-Phase12BNoReparse $operationRoot) -or @(Get-ChildItem -LiteralPath $operationRoot -Force).Count -ne 0){throw 'Published runner root conflicts with current migration staging.'}
            Remove-Item -LiteralPath $operationRoot -Force
        }
        if($ApplyAcl){& $ApplyAcl $target}
        return [pscustomobject]@{State='ALREADY_PUBLISHED';Target=$target;Staging=$stagingRunner}
    }
    if(Test-Path -LiteralPath $operationRoot){
        if(-not(Test-Phase12BNoReparse $operationRoot)){throw 'Current migration staging is unsafe.'}
        $entries=@(Get-ChildItem -LiteralPath $operationRoot -Force)
        if(@($entries|Where-Object{$_.Name -cne 'runner'}).Count -ne 0){throw 'Current migration staging contains unknown content.'}
        if(Test-Path -LiteralPath $stagingRunner){
            if(-not(Test-Phase12BRunnerPackageTree $stagingRunner)){
                $resolvedOperation=[IO.Path]::GetFullPath($operationRoot);$resolvedStaging=[IO.Path]::GetFullPath($stagingRoot)+[IO.Path]::DirectorySeparatorChar
                if(-not $resolvedOperation.StartsWith($resolvedStaging,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing unsafe staging cleanup.'}
                Remove-Item -LiteralPath $operationRoot -Recurse -Force
            }
        }
    }
    if(-not(Test-Path -LiteralPath $stagingRunner -PathType Container)){
        New-Item -ItemType Directory -Path $stagingRunner -Force|Out-Null
        if($ApplyAcl){foreach($path in @($stagingRoot,$operationRoot,$stagingRunner)){& $ApplyAcl $path}}
        Expand-Archive -LiteralPath $PackagePath -DestinationPath $stagingRunner -ErrorAction Stop
    }
    if(-not(Test-Phase12BRunnerPackageTree $stagingRunner)){throw 'Extracted runner package tree is incomplete.'}
    if(Test-Path -LiteralPath $target){throw 'Final runner root appeared before atomic publication.'}
    [IO.Directory]::Move($stagingRunner,$target)
    if(-not(Test-Phase12BRunnerPackageTree $target)){throw 'Published runner root failed read-back.'}
    if($ApplyAcl){& $ApplyAcl $target}
    if(Test-Path -LiteralPath $operationRoot){
        if(@(Get-ChildItem -LiteralPath $operationRoot -Force).Count -ne 0){throw 'Migration staging was not empty after publication.'}
        Remove-Item -LiteralPath $operationRoot -Force
    }
    [pscustomobject]@{State='PUBLISHED';Target=$target;Staging=$stagingRunner}
}

function Get-Phase12BMigrationRepositoryIdentityMatch {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$IntentRepositoryId,
        [Parameter(Mandatory)][string]$IntentRepositoryFullName,
        [Parameter(Mandatory)][string]$CallerRepositoryId,
        [Parameter(Mandatory)][string]$CallerRepositoryFullName,
        [AllowEmptyString()][string]$ActualRepositoryId,
        [AllowEmptyString()][string]$ActualRepositoryFullName,
        [Parameter(Mandatory)][bool]$ReadSucceeded
    )
    $idPattern='^[1-9][0-9]*$'
    $namePattern='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
    $intentValid=$IntentRepositoryId -match $idPattern -and $IntentRepositoryFullName -match $namePattern
    $callerValid=$CallerRepositoryId -match $idPattern -and $CallerRepositoryFullName -match $namePattern
    $actualValid=$ReadSucceeded -and $ActualRepositoryId -match $idPattern -and $ActualRepositoryFullName -match $namePattern
    $unknownState=-not $ReadSucceeded -or -not $actualValid
    $identityConflict=-not($intentValid -and $callerValid) -or (
        $actualValid -and -not(
            $IntentRepositoryId -ceq $CallerRepositoryId -and
            $CallerRepositoryId -ceq $ActualRepositoryId -and
            $IntentRepositoryFullName -ceq $CallerRepositoryFullName -and
            $CallerRepositoryFullName -ceq $ActualRepositoryFullName
        )
    )
    [pscustomobject]@{
        Exact=(-not $unknownState -and -not $identityConflict)
        IdentityConflict=$identityConflict
        UnknownState=$unknownState
        ActualRepositoryId=$ActualRepositoryId
        ActualRepositoryFullName=$ActualRepositoryFullName
    }
}

function Get-Phase12BLegacyRunnerIdentityMatch {
    [CmdletBinding()]param(
        [Parameter(Mandatory)]$LocalRunner,
        [Parameter(Mandatory)][string]$CallerRepository,
        [Parameter(Mandatory)][string]$CallerRepositoryId,
        [Parameter(Mandatory)][string]$ActualRepositoryId,
        [AllowEmptyString()][string]$ActualRepositoryFullName,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GitHubRunners,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedLabels
    )
    $agentId=if($LocalRunner.PSObject.Properties['agentId']){[string]$LocalRunner.agentId}else{''}
    $agentName=if($LocalRunner.PSObject.Properties['agentName']){[string]$LocalRunner.agentName}else{''}
    $repositoryUrl=if($LocalRunner.PSObject.Properties['gitHubUrl']){[string]$LocalRunner.gitHubUrl}else{''}
    $idValid=$agentId -match '^[1-9][0-9]*$';$nameValid=$agentName -match '^[A-Za-z0-9_.-]+$'
    $localRepositoryExact=$repositoryUrl.TrimEnd('/') -ieq "https://github.com/$CallerRepository"
    $repositoryExact=$CallerRepositoryId -match '^[1-9][0-9]*$' -and $ActualRepositoryId -ceq $CallerRepositoryId -and $ActualRepositoryFullName -ceq $CallerRepository
    $both=@($GitHubRunners|Where-Object{[string]$_.id -ceq $agentId -and [string]$_.name -ceq $agentName})
    $byId=@($GitHubRunners|Where-Object{[string]$_.id -ceq $agentId})
    $byName=@($GitHubRunners|Where-Object{[string]$_.name -ceq $agentName})
    $labels=if($both.Count -eq 1 -and $both[0].PSObject.Properties['labels']){@($both[0].labels|ForEach-Object{[string]$_.name}|Where-Object{$_}|Sort-Object -Unique)}else{@()}
    $labelsExact=$both.Count -eq 1 -and @(Compare-Object ($ExpectedLabels|Sort-Object -Unique) $labels).Count -eq 0
    [pscustomobject]@{
        LegacyRunnerId=$agentId;LegacyRunnerName=$agentName
        LocalRunnerMetadataExact=($idValid -and $nameValid -and $localRepositoryExact)
        RepositoryMismatch=(-not $localRepositoryExact -or -not $repositoryExact)
        RunnerNameMismatch=(-not $nameValid -or ($byId.Count -eq 1 -and [string]$byId[0].name -cne $agentName))
        RunnerIdMismatch=(-not $idValid -or ($byName.Count -eq 1 -and [string]$byName[0].id -cne $agentId))
        DuplicateGitHubRunner=($both.Count -gt 1 -or $byId.Count -gt 1 -or $byName.Count -gt 1)
        GitHubRunnerCount=$both.Count;GitHubRunnerExact=$labelsExact
        GitHubRunnerStatus=if($both.Count -eq 1){[string]$both[0].status}else{'unknown'}
        GitHubRunnerBusy=if($both.Count -eq 1){[bool]$both[0].busy}else{$true}
    }
}

function Test-Phase12BFileSha256 {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSha256)
    if($ExpectedSha256 -notmatch '^[0-9a-f]{64}$' -or -not(Test-Path -LiteralPath $Path -PathType Leaf) -or -not(Test-Phase12BNoReparse $Path)){return $false}
    try{$hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}catch{return $false}
    $hash -ceq $ExpectedSha256
}

function Get-Phase12BMigrationIntentPath {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RuntimeRoot)
    if(-not[IO.Path]::IsPathRooted($RuntimeRoot)){throw 'Runtime root must be absolute.'}
    [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'migration\host-migration.json'))
}

function Test-Phase12BMigrationIntent {
    [CmdletBinding()]param([Parameter(Mandatory)]$Intent)
    $required=@('schema','operation','operation_id','source_state','repository_id','repository_full_name','legacy_runner_directory','legacy_runner_id','legacy_runner_name','execution_area_id','target_runner_directory','target_runner_name','package_version','package_sha256','dispatch_initial_state','dispatch_restore_required','migration_stage','state_entered_at')
    $actual=@($Intent.PSObject.Properties.Name|Sort-Object)
    if(@(Compare-Object ($required|Sort-Object) $actual).Count -ne 0){return $false}
    if([string]$Intent.schema -ne '1' -or [string]$Intent.operation -cne 'PHASE12B_LEGACY_HOST_MIGRATION' -or [string]$Intent.source_state -cne 'LEGACY_PHASE10_INTERACTIVE'){return $false}
    if([string]$Intent.repository_id -notmatch '^[1-9][0-9]*$' -or [string]$Intent.repository_full_name -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){return $false}
    if(-not[IO.Path]::IsPathRooted([string]$Intent.legacy_runner_directory) -or -not[IO.Path]::IsPathRooted([string]$Intent.target_runner_directory)){return $false}
    if([string]$Intent.legacy_runner_id -notmatch '^[1-9][0-9]*$' -or [string]$Intent.legacy_runner_name -notmatch '^[A-Za-z0-9_.-]+$' -or [string]$Intent.target_runner_name -notmatch '^codex-repo-[1-9][0-9]*$'){return $false}
    if([string]$Intent.package_version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$Intent.package_sha256 -notmatch '^[0-9a-f]{64}$'){return $false}
    if([string]$Intent.dispatch_initial_state -cne 'active' -or -not($Intent.dispatch_restore_required -is [bool]) -or -not[bool]$Intent.dispatch_restore_required){return $false}
    $operationGuid=[guid]::Empty;if(-not[guid]::TryParseExact([string]$Intent.operation_id,'D',[ref]$operationGuid)){return $false}
    $guid=[guid]::Empty;if(-not[guid]::TryParse([string]$Intent.execution_area_id,[ref]$guid)){return $false}
    if([string]$Intent.migration_stage -notin $script:Phase12BMigrationStages){return $false}
    $timestamp=[DateTimeOffset]::MinValue
    [DateTimeOffset]::TryParseExact([string]$Intent.state_entered_at,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp) -and $timestamp.Offset -eq [TimeSpan]::Zero
}

function Read-Phase12BMigrationIntent {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RuntimeRoot)
    $path=Get-Phase12BMigrationIntentPath $RuntimeRoot
    if(-not(Test-Path -LiteralPath $path)){return $null}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or -not(Test-Phase12BNoReparse $path)){throw 'Migration intent path is unsafe.'}
    try {
        $raw=Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $convertFromJson=Get-Command ConvertFrom-Json -ErrorAction Stop
        $dateKindSupported=$convertFromJson.Parameters.ContainsKey('DateKind')
        if($dateKindSupported){$intent=$raw|ConvertFrom-Json -DateKind String -ErrorAction Stop}
        else{$intent=$raw|ConvertFrom-Json -ErrorAction Stop}
        # Windows PowerShell 5.1 eagerly converts ISO timestamps to DateTime.
        # Restore the exact UTC wire value before strict contract validation so
        # parsing remains equivalent to PowerShell 7's -DateKind String.
        $timestampMatches=[regex]::Matches($raw,'"state_entered_at"\s*:\s*"(?<value>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00))"')
        if($timestampMatches.Count -eq 1){$intent.state_entered_at=$timestampMatches[0].Groups['value'].Value}
    } catch {throw 'Migration intent is malformed.'}
    if(-not(Test-Phase12BMigrationIntent $intent)){throw 'Migration intent contract is invalid.'}
    $intent
}

function Write-Phase12BMigrationIntent {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)]$Identity
    )
    if($Stage -notin $script:Phase12BMigrationStages){throw 'Unsupported migration stage.'}
    $path=Get-Phase12BMigrationIntentPath $RuntimeRoot;$directory=Split-Path -Parent $path
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    if(-not(Test-Phase12BNoReparse $directory)){throw 'Migration intent directory is unsafe.'}
    $dispatchInitialState=if($Identity.PSObject.Properties['DispatchInitialState']){[string]$Identity.DispatchInitialState}else{'active'}
    $dispatchRestoreRequired=if($Identity.PSObject.Properties['DispatchRestoreRequired']){[bool]$Identity.DispatchRestoreRequired}else{$true}
    $intent=[ordered]@{schema=1;operation='PHASE12B_LEGACY_HOST_MIGRATION';operation_id=[string]$Identity.OperationId;source_state='LEGACY_PHASE10_INTERACTIVE';repository_id=[string]$Identity.RepositoryId;repository_full_name=[string]$Identity.RepositoryFullName;legacy_runner_directory=[IO.Path]::GetFullPath([string]$Identity.LegacyRunnerDirectory);legacy_runner_id=[string]$Identity.LegacyRunnerId;legacy_runner_name=[string]$Identity.LegacyRunnerName;execution_area_id=[string]$Identity.ExecutionAreaId;target_runner_directory=[IO.Path]::GetFullPath([string]$Identity.TargetRunnerDirectory);target_runner_name=[string]$Identity.TargetRunnerName;package_version=[string]$Identity.PackageVersion;package_sha256=[string]$Identity.PackageSha256;dispatch_initial_state=$dispatchInitialState;dispatch_restore_required=$dispatchRestoreRequired;migration_stage=$Stage;state_entered_at=[DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
    if(-not(Test-Phase12BMigrationIntent ([pscustomobject]$intent))){throw 'Refusing invalid migration intent.'}
    $temp=Join-Path $directory ('.host-migration.'+[guid]::NewGuid().ToString('N')+'.tmp');$backup=Join-Path $directory ('.host-migration.'+[guid]::NewGuid().ToString('N')+'.bak')
    try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($intent|ConvertTo-Json -Compress));$stream=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,$backup,$true);Remove-Item -LiteralPath $backup -Force}else{[IO.File]::Move($temp,$path)}}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force};if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force}}
    [pscustomobject]$intent
}

function Initialize-Phase12BMigrationIntent {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)]$Identity
    )
    $target=[IO.Path]::GetFullPath($RuntimeRoot)
    if(Test-Path -LiteralPath $target){throw 'Migration runtime root already exists; use the resume path.'}
    $parent=Split-Path -Parent $target;$leaf=Split-Path -Leaf $target
    if(-not(Test-Path -LiteralPath $parent -PathType Container) -or -not(Test-Phase12BNoReparse $parent)){throw 'Migration runtime parent is unsafe.'}
    $staging=Join-Path $parent ('.'+$leaf+'.migration.'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        New-Item -ItemType Directory -Path (Join-Path $staging 'migration') -Force|Out-Null
        Write-Phase12BMigrationIntent -RuntimeRoot $staging -Stage LEGACY_VERIFIED -Identity $Identity|Out-Null
        [IO.Directory]::Move($staging,$target)
        $read=Read-Phase12BMigrationIntent -RuntimeRoot $target
        if($null -eq $read -or [string]$read.migration_stage -cne 'LEGACY_VERIFIED'){throw 'Initial migration intent publication read-back failed.'}
        $read
    } finally {
        if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force}
    }
}

function Get-Phase12BMigrationSourceState {
    [CmdletBinding()]param([Parameter(Mandatory)]$Observation)
    if([string]$Observation.HostState -eq 'EXISTING' -and [bool]$Observation.CurrentManagedExact){return 'CURRENT_MANAGED'}
    $identityConflict=[bool]$Observation.IdentityConflict -or [bool]$Observation.DuplicateGitHubRunner -or [bool]$Observation.UnexpectedService -or [bool]$Observation.RepositoryMismatch -or [bool]$Observation.RunnerNameMismatch -or [bool]$Observation.RunnerIdMismatch
    if($identityConflict){return 'CONFLICT'}
    $legacyEvidence=[bool]$Observation.ExecutionRootPresent -or [bool]$Observation.LegacyRunnerPresent -or [int]$Observation.GitHubRunnerCount -gt 0
    $exact=[string]$Observation.HostState -eq 'INCONSISTENT' -and [bool]$Observation.ExecutionRootPresent -and [bool]$Observation.ExecutionInspect -and [bool]$Observation.ExecutionPreflight -and [bool]$Observation.ExecutionAreaIdExact -and [string]$Observation.CurrentRunState -eq 'ABSENT' -and [string]$Observation.MutexState -eq 'FREE' -and [bool]$Observation.ResidualClean -and -not[bool]$Observation.CredentialResidue -and [int]$Observation.RelevantProcessCount -eq 0 -and [bool]$Observation.LegacyRunnerPresent -and [bool]$Observation.LegacyRunnerSafe -and [bool]$Observation.LegacyRunnerFilesExact -and [bool]$Observation.LocalRunnerMetadataExact -and [int]$Observation.GitHubRunnerCount -eq 1 -and [bool]$Observation.GitHubRunnerExact -and [string]$Observation.GitHubRunnerStatus -eq 'offline' -and -not[bool]$Observation.GitHubRunnerBusy -and [int]$Observation.ActiveGitHubJobCount -eq 0 -and -not[bool]$Observation.LegacyServicePresent -and [int]$Observation.RunnerProcessCount -eq 0 -and [bool]$Observation.TargetRootsAbsent -and [bool]$Observation.DispatchInitiallyActive -and [string]$Observation.WorkflowState -in @('MANAGED_OLD','EXACT_TARGET')
    if($exact){return 'LEGACY_PHASE10_INTERACTIVE'}
    if($legacyEvidence){return 'UNSUPPORTED_PARTIAL'}
    'CONFLICT'
}

function Get-Phase12BMigrationRecoveryDecision {
    [CmdletBinding()]param([string]$Stage,[Parameter(Mandatory)]$Actual)
    if([bool]$Actual.IdentityConflict -or [bool]$Actual.UnknownState){return 'MANUAL_INTERVENTION_REQUIRED'}
    if([bool]$Actual.LegacyRegistered -and [bool]$Actual.TargetRegistered){return 'MANUAL_INTERVENTION_REQUIRED'}
    if([string]::IsNullOrWhiteSpace($Stage)){return 'RETRY_SAFE'}
    if($Stage -notin $script:Phase12BMigrationStages){return 'MANUAL_INTERVENTION_REQUIRED'}
    if([bool]$Actual.PostconditionMatchesStage -or [bool]$Actual.NextStagePostcondition){return 'RESUME_SAFE'}
    if([bool]$Actual.SafeApprovedRecoveryCandidate){return 'RECOVER_WITH_APPROVAL'}
    'MANUAL_INTERVENTION_REQUIRED'
}

function Test-Phase12BMigrationStageTopology {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Stage,[Parameter(Mandatory)]$Actual)
    if($Stage -notin $script:Phase12BMigrationStages -or $Actual.IdentityConflict -or $Actual.UnknownState -or -not $Actual.LegacyDirectoryRetained){return $false}
    switch($Stage){
      'LEGACY_VERIFIED' { return $Actual.LegacyRegistered -and -not $Actual.TargetRegistered -and -not $Actual.DispatchFenced }
      'DISPATCH_FENCING' { return $Actual.LegacyRegistered -and -not $Actual.TargetRegistered -and $Actual.DispatchStateKnown }
      'DISPATCH_FENCED' { return $Actual.LegacyRegistered -and -not $Actual.TargetRegistered -and $Actual.DispatchFenced }
      'QUIESCENT' { return $Actual.LegacyRegistered -and -not $Actual.TargetRegistered -and $Actual.DispatchFenced -and $Actual.Quiescent }
      'TARGET_HOST_PREPARED' { return $Actual.LegacyRegistered -and -not $Actual.TargetRegistered -and $Actual.DispatchFenced -and $Actual.Quiescent -and $Actual.TargetHostPrepared -and $Actual.PackageVerified -and $Actual.ExecutionAreaIdPreserved -and $Actual.AclExact }
      'LEGACY_RUNNER_UNREGISTERING' { return -not $Actual.TargetRegistered -and $Actual.DispatchFenced -and $Actual.TargetHostPrepared }
      'LEGACY_RUNNER_UNREGISTERED' { return -not $Actual.LegacyRegistered -and -not $Actual.TargetRegistered -and $Actual.DispatchFenced -and $Actual.TargetHostPrepared }
      'TARGET_RUNNER_REGISTERING' { return -not $Actual.LegacyRegistered -and $Actual.DispatchFenced -and $Actual.TargetHostPrepared }
      'TARGET_RUNNER_REGISTERED' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.DispatchFenced }
      'SERVICE_INSTALLING' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.DispatchFenced }
      'SERVICE_INSTALLED' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.ServiceInstalled -and $Actual.ServiceExact -and $Actual.DispatchFenced }
      'SERVICE_RUNNING' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.ServiceRunning -and $Actual.ServiceExact -and $Actual.DispatchFenced }
      # ACTIVE_VERIFIED with dispatch already restored is the legacy post-restore,
      # pre-persistence crash window.  All other exact postconditions still apply.
      'ACTIVE_VERIFIED' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.ServiceRunning -and $Actual.ServiceExact -and $Actual.ActiveExact }
      'DISPATCH_RESTORING' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.ServiceRunning -and $Actual.ServiceExact -and $Actual.ActiveExact }
      'DISPATCH_RESTORED' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.ServiceRunning -and $Actual.ServiceExact -and $Actual.ActiveExact -and -not $Actual.DispatchFenced }
      'MIGRATION_COMPLETE' { return -not $Actual.LegacyRegistered -and $Actual.TargetRegistered -and $Actual.ServiceRunning -and $Actual.ServiceExact -and $Actual.ActiveExact -and -not $Actual.DispatchFenced -and $Actual.ExecutionAreaIdPreserved }
    }
    $false
}

function Invoke-Phase12BMigrationLifecycle {
    [CmdletBinding()]param(
        [Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$InitialStage,
        [Parameter(Mandatory)][scriptblock]$ReadState,[Parameter(Mandatory)][scriptblock]$Mutate,[Parameter(Mandatory)][scriptblock]$Persist
    )
    if($InitialStage -notin $script:Phase12BMigrationStages){throw 'Migration lifecycle stage is invalid.'}
    $stage=$InitialStage
    function Save([string]$s){& $Persist $s $Identity|Out-Null;$script:phase12bStage=$s}
    function State(){& $ReadState}
    $script:phase12bStage=$stage
    $s=State
    if($s.IdentityConflict -or $s.UnknownState){throw 'Migration actual state is ambiguous.'}
    if(-not(Test-Phase12BMigrationStageTopology -Stage $stage -Actual $s)){throw 'Migration stage contradicts actual topology.'}
    if($stage -eq 'MIGRATION_COMPLETE'){
        if($s.DispatchFenced -or -not($s.ActiveExact -and $s.TargetRegistered -and $s.ServiceRunning -and $s.ServiceExact -and $s.ExecutionAreaIdPreserved -and $s.LegacyDirectoryRetained) -or $s.LegacyRegistered){throw 'Completed migration postcondition is not exact.'}
        return [pscustomobject]@{Result='PASS';Stage=$stage;Postcondition='MIGRATION_COMPLETE'}
    }
    if($stage -eq 'LEGACY_VERIFIED'){if($s.DispatchFenced){throw 'LEGACY_VERIFIED cannot have a preexisting disabled dispatch state.'};Save 'DISPATCH_FENCING';$stage='DISPATCH_FENCING'}
    if($stage -eq 'DISPATCH_FENCING'){$s=State;if(-not $s.DispatchStateKnown){throw 'Dispatch state is unknown.'};if(-not $s.DispatchFenced){& $Mutate 'FenceDispatch';$s=State};if(-not $s.DispatchFenced){throw 'Dispatch fence read-back failed.'};Save 'DISPATCH_FENCED';$stage='DISPATCH_FENCED'}
    if($stage -eq 'DISPATCH_FENCED'){$s=State;if(-not $s.Quiescent){& $Mutate 'WaitForQuiescence';$s=State};if(-not $s.Quiescent){throw 'Migration quiescence is not proven.'};Save 'QUIESCENT';$stage='QUIESCENT'}
    if($stage -eq 'QUIESCENT'){if(-not $s.TargetHostPrepared){& $Mutate 'PrepareTargetHost'};$s=State;if(-not($s.TargetHostPrepared -and $s.PackageVerified -and $s.ExecutionAreaIdPreserved -and $s.AclExact)){throw 'Target host preparation read-back failed.'};Save 'TARGET_HOST_PREPARED';$stage='TARGET_HOST_PREPARED'}
    if($stage -eq 'TARGET_HOST_PREPARED'){& $Mutate 'WaitForQuiescence';$s=State;if(-not $s.Quiescent){throw 'Migration quiescence is not proven immediately before unregister.'};Save 'LEGACY_RUNNER_UNREGISTERING';$stage='LEGACY_RUNNER_UNREGISTERING'}
    if($stage -eq 'LEGACY_RUNNER_UNREGISTERING'){& $Mutate 'WaitForQuiescence';$s=State;if(-not $s.Quiescent){throw 'Migration quiescence is not proven before legacy unregister.'};if($s.LegacyRegistered){& $Mutate 'UnregisterLegacy'};$s=State;if($s.LegacyRegistered){throw 'Legacy runner unregister read-back failed.'};Save 'LEGACY_RUNNER_UNREGISTERED';$stage='LEGACY_RUNNER_UNREGISTERED'}
    if($stage -eq 'LEGACY_RUNNER_UNREGISTERED'){Save 'TARGET_RUNNER_REGISTERING';$stage='TARGET_RUNNER_REGISTERING'}
    if($stage -eq 'TARGET_RUNNER_REGISTERING'){if(-not $s.TargetRegistered){& $Mutate 'RegisterTarget'};$s=State;if(-not $s.TargetRegistered -or $s.LegacyRegistered){throw 'Target runner registration read-back failed.'};Save 'TARGET_RUNNER_REGISTERED';$stage='TARGET_RUNNER_REGISTERED'}
    if($stage -eq 'TARGET_RUNNER_REGISTERED'){Save 'SERVICE_INSTALLING';$stage='SERVICE_INSTALLING'}
    if($stage -eq 'SERVICE_INSTALLING'){if(-not $s.ServiceInstalled){& $Mutate 'InstallService'};$s=State;if(-not $s.ServiceInstalled){throw 'Official Service installation read-back failed.'};Save 'SERVICE_INSTALLED';$stage='SERVICE_INSTALLED'}
    if($stage -eq 'SERVICE_INSTALLED'){if(-not $s.ServiceRunning){& $Mutate 'StartService'};$s=State;if(-not($s.ServiceRunning -and $s.ServiceExact)){throw 'Service Running read-back failed.'};Save 'SERVICE_RUNNING';$stage='SERVICE_RUNNING'}
    if($stage -eq 'SERVICE_RUNNING'){if(-not $s.ActiveExact){& $Mutate 'WriteActiveMetadata'};$s=State;if(-not($s.ActiveExact -and $s.ExecutionAreaIdPreserved)){throw 'ACTIVE verification failed.'};Save 'ACTIVE_VERIFIED';$stage='ACTIVE_VERIFIED'}
    if($stage -eq 'ACTIVE_VERIFIED'){Save 'DISPATCH_RESTORING';$stage='DISPATCH_RESTORING'}
    if($stage -eq 'DISPATCH_RESTORING'){if($s.DispatchFenced){& $Mutate 'RestoreDispatch'};$s=State;if($s.DispatchFenced -or -not($s.ActiveExact -and $s.TargetRegistered -and $s.ServiceRunning -and $s.ServiceExact -and $s.ExecutionAreaIdPreserved -and $s.LegacyDirectoryRetained) -or $s.LegacyRegistered){throw 'Dispatch restoration read-back failed.'};Save 'DISPATCH_RESTORED';$stage='DISPATCH_RESTORED'}
    if($stage -eq 'DISPATCH_RESTORED'){$s=State;if($s.DispatchFenced -or -not($s.ActiveExact -and $s.TargetRegistered -and $s.ServiceRunning -and $s.ServiceExact -and $s.ExecutionAreaIdPreserved -and $s.LegacyDirectoryRetained) -or $s.LegacyRegistered){throw 'Migration final verification failed.'};Save 'MIGRATION_COMPLETE';$stage='MIGRATION_COMPLETE'}
    [pscustomobject]@{Result='PASS';Stage=$stage;Postcondition='MIGRATION_COMPLETE'}
}

Export-ModuleMember -Function Test-Phase12BYqV4Version,Test-Phase12BFileAttributesSafe,Test-Phase12BNoReparse,Get-Phase12BCallerRunnerRoot,Get-Phase12BExpectedRunnerName,Get-Phase12BExpectedServiceName,Test-Phase12BServicePath,Test-Phase12BTestAdapter,Read-Phase12BRuntime,Get-Phase12BHostState,Get-Phase12BServiceForRunner,Get-Phase12BRunnerState,Test-Phase12BAclPolicy,Read-Phase12BConfig,Get-Phase12BExternalCallerState,Test-Phase12BExternalCallerState,Invoke-Phase12BAction,Test-Phase12BQuiescent,Assert-Phase12BRepositoryIdentity,Get-Phase12BCallerRunnerIdentity,Get-Phase12BOnboardPackageOperationId,Get-Phase12BFixedRunnerAdapterArguments,Get-Phase12BRunnerMetadataPath,Test-Phase12BMetadataIdentity,Read-Phase12BRunnerMetadata,Write-Phase12BRunnerMetadata,Get-Phase12BCallerRunnerClassification,Read-Phase12BHostConfig,Assert-Phase12BFixtureRoot,Read-Phase12BCallerRunnerFixture,Write-Phase12BCallerRunnerFixture,Get-Phase12BQuiescenceDecision,Get-Phase12BExecutionMutexState,Read-Phase12BCurrentRunState,Get-Phase12BGitHubActiveJobCount,Get-Phase12BResidualState,Wait-Phase12BCallerQuiescence,Get-Phase12BCallerRunnerObservation,Invoke-Phase12BCallerRunner,Get-Phase12BRunnerPackageContract,Test-Phase12BRunnerPackage,Test-Phase12BRunnerReleaseAsset,Get-Phase12BCompleteRunnerList,Get-Phase12BGitHubRunnerList,Test-Phase12BRunnerPackageTree,Assert-Phase12BRunnerStagingAuthority,Install-Phase12BRunnerPackageAtomically,Get-Phase12BMigrationRepositoryIdentityMatch,Get-Phase12BLegacyRunnerIdentityMatch,Test-Phase12BFileSha256,Get-Phase12BMigrationIntentPath,Test-Phase12BMigrationIntent,Read-Phase12BMigrationIntent,Write-Phase12BMigrationIntent,Initialize-Phase12BMigrationIntent,Get-Phase12BMigrationSourceState,Get-Phase12BMigrationRecoveryDecision,Test-Phase12BMigrationStageTopology,Invoke-Phase12BMigrationLifecycle
