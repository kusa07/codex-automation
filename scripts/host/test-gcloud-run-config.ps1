$ErrorActionPreference='Stop'
$helper=Join-Path $PSScriptRoot 'manage-gcloud-run-config.ps1'
$workflow=Join-Path $PSScriptRoot '..\..\.github\workflows\codex-run.yml'
$source=Get-Content -LiteralPath $helper -Raw -ErrorAction Stop
$yaml=Get-Content -LiteralPath $workflow -Raw -ErrorAction Stop
foreach($part in @('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_REPOSITORY_ID','RUNNER_TEMP','S-1-5-20',
    'repo-','_work','_temp','codex-gcloud-','CLOUDSDK_PYTHON=','CLOUDSDK_CONFIG=',
    'PYTHONPATH','PYTHONHOME','CLOUDSDK_PYTHON_SITEPACKAGES','CLOUDSDK_PYTHON_ARGS','PYTHONNOUSERSITE=1',
    'Assert-NonReparse','Assert-ConfigAcl','AreAccessRulesProtected','.codex-gcloud-owned.json',
    'Remove-Item -LiteralPath $config -Recurse -Force')) {
    if(-not $source.Contains($part)){throw "Google Cloud runtime ownership guard is missing: $part"}
}
if($source -notmatch "Add-Content -LiteralPath \`$env:GITHUB_ENV -Value \(\`$name \+ '= '\)" -and
   $source -notmatch "Add-Content -LiteralPath \`$env:GITHUB_ENV -Value \(\`$name \+ '='\)"){
  throw 'Inherited Python environment variables are not cleared in the GitHub job environment.'
}
$preparePosition=$source.IndexOf("if (`$Action -eq 'Prepare')",[StringComparison]::Ordinal)
$scanPosition=$source.IndexOf('Assert-NoGcloudSiblingResidue $temp',$preparePosition,[StringComparison]::Ordinal)
$createPosition=$source.IndexOf('New-Item -ItemType Directory -Path $config',$preparePosition,[StringComparison]::Ordinal)
if($preparePosition -lt 0 -or $scanPosition -lt $preparePosition -or $createPosition -le $scanPosition){
  throw 'Production Prepare does not reject stale config namespace before creating a new directory.'
}
if(@([regex]::Matches($yaml,'(?m)^      - name: Prepare isolated Google Cloud CLI runtime$')).Count -ne 2 -or
   @([regex]::Matches($yaml,'(?m)^      - name: Remove isolated Google Cloud CLI config$')).Count -ne 2){throw 'Both active Windows jobs must prepare and clean Google Cloud config.'}
$windows = $yaml.Substring($yaml.IndexOf('  self-hosted-read-only-validation:'))
if(@([regex]::Matches($windows,'google-github-actions/setup-gcloud@')).Count -ne 2 -or
   @([regex]::Matches($windows,'(?m)^        if: always\(\)$')).Count -lt 2){throw 'Active Windows setup-gcloud/cleanup paths are incomplete.'}
# Import only the production namespace decision function from the AST. No
# TestMode branch or fake NETWORK SERVICE identity is introduced.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if(@($errors).Count -ne 0){throw 'Google Cloud config helper cannot be parsed.'}
$functions=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-NoGcloudSiblingResidue'},$true))
if($functions.Count -ne 1){throw 'Shared Google Cloud residue decision function is unavailable.'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture=Join-Path $tempRoot ('phase12b-gcloud-namespace-' + [guid]::NewGuid().ToString('N'))
if(-not ([IO.Path]::GetFullPath($fixture)).StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Gcloud test fixture escaped temp root.'}
try{
  New-Item -ItemType Directory -Path $fixture -ErrorAction Stop|Out-Null
  Assert-NoGcloudSiblingResidue $fixture
  $unrelated=Join-Path $fixture 'unrelated.txt';[IO.File]::WriteAllText($unrelated,'safe')
  Assert-NoGcloudSiblingResidue $fixture
  foreach($name in @('codex-gcloud-111-1','Codex-GCloud-222-1')){
    $stale=Join-Path $fixture $name
    [IO.File]::WriteAllText($stale,'residue')
    $stopped=$false;try{Assert-NoGcloudSiblingResidue $fixture}catch{$stopped=$true}
    if(-not $stopped -or -not(Test-Path -LiteralPath $stale -PathType Leaf)){throw 'Stale Google Cloud file was adopted, deleted, or ignored.'}
    Remove-Item -LiteralPath $stale -Force -ErrorAction Stop
  }
  $staleDirectory=Join-Path $fixture 'codex-gcloud-333-1'
  New-Item -ItemType Directory -Path $staleDirectory -ErrorAction Stop|Out-Null
  $stopped=$false;try{Assert-NoGcloudSiblingResidue $fixture}catch{$stopped=$true}
  if(-not $stopped -or -not(Test-Path -LiteralPath $staleDirectory -PathType Container)){throw 'Stale Google Cloud directory was adopted, deleted, or ignored.'}
}finally{
  if(Test-Path -LiteralPath $fixture){
    foreach($item in @(Get-ChildItem -LiteralPath $fixture -Force -Recurse -ErrorAction Stop)){
      if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Gcloud test fixture contains a reparse point; manual cleanup required.'}
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
  }
}
$old=@{}
foreach($name in @('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_REPOSITORY_ID','RUNNER_TEMP')){$old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
  $env:GITHUB_RUN_ID='123';$env:GITHUB_RUN_ATTEMPT='1';$env:GITHUB_REPOSITORY_ID='999';$env:RUNNER_TEMP='C:\not-the-managed-runner\_work\_temp'
  $failed=$false
  try{& $helper -Action Prepare|Out-Null}catch{$failed=$true}
  if(-not $failed){throw 'Non-NETWORK SERVICE process accepted Google Cloud config preparation.'}
}finally{foreach($name in $old.Keys){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}}
'GCLOUD_RUN_CONFIG_TEST=PASS'
