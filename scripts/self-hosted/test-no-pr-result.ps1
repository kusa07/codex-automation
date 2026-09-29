$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'no-pr-result.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("codex-no-pr-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$context = @{
    Repository = 'owner/repo'; RepositoryId = '123'; IssueNumber = '25'
    RunId = '567'; RunAttempt = '1'; ExecutionId = 'repo-123-run-567-attempt-1'
    OwnerNonce = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; BaseSha = '0000000000000000000000000000000000000000'
}
function Write-Result([string]$Value) {
    [IO.File]::WriteAllText((Join-Path $root 'result.json'), $Value, [Text.UTF8Encoding]::new($false))
}
function Prepare([string]$Name) {
    $candidate = Join-Path $root "$Name.json"
    & $helper -Action Prepare -CandidatePath $candidate -ResultPath (Join-Path $root 'result.json') @context
    if ($LASTEXITCODE -ne 0) { throw "Prepare failed: $Name" }
    return (Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json -AsHashtable)
}
try {
    Write-Result '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Already satisfied safely."}'
    $noChanges = Prepare 'no-change'
    if ($noChanges.result -cne 'NO_CHANGES' -or $noChanges.reason_code -cne 'NO_CHANGE_NEEDED' -or $noChanges.summary -cne 'Already satisfied safely.') { throw 'No-change result failed.' }

    Write-Result '{"outcome":"STOP_AND_REPORT","reason_code":"REQUIRES_USER_DECISION","summary":"A product decision is required."}'
    $stop = Prepare 'stop'
    if ($stop.result -cne 'STOP_AND_REPORT' -or $stop.reason_code -cne 'REQUIRES_USER_DECISION') { throw 'Stop result failed.' }

    Write-Result '{"outcome":"IMPLEMENTED","reason_code":"IMPLEMENTED","summary":"I implemented files that do not exist."}'
    $implemented = Prepare 'implemented-claim'
    if ($implemented.result -cne 'NO_CHANGES' -or $implemented.summary -clike '*I implemented*') { throw 'Model implementation claim overrode actual zero changes.' }

    Write-Result '{"outcome":"STOP_AND_REPORT","reason_code":"BLOCKED_BY_ENVIRONMENT","summary":"Bearer x-secret-token"}'
    $secret = Prepare 'unsafe-summary'
    if ($secret.summary -clike '*x-secret-token*' -or $secret.summary -cnotlike '*not published*') { throw 'Credential-like summary escaped sanitization.' }

    foreach ($size in @(40, 64)) {
        $hash = 'a' * $size
        Write-Result ('{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"' + $hash + '"}')
        $hashResult = Prepare "hash-$size"
        if ($hashResult.summary -ceq $hash) { throw "$size-character hash escaped sanitization." }
    }
    Write-Result '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.signature123456"}'
    $jwt = Prepare 'jwt-summary'
    if ($jwt.summary -clike 'eyJ*') { throw 'JWT-like summary escaped sanitization.' }

    $unsafeSummaries = @(
        'Please see https://example.invalid/docs and notify @octocat [details](https://example.invalid).',
        'Contact @octocat for review.',
        'Review [details](more).',
        '<strong>Action required</strong>',
        'sk-proj-abcdefghijklmnopqrstuvwx1234567890',
        '- Markdown bullet',
        'token abcdefghijklmnopqrstuvwxyz1234567890',
        'secret abcdefghijklmnopqrstuvwxyz1234567890',
        'xoxb-synthetic-example',
        'AKIAABCDEFGHIJKLMNOP',
        'credential material was found',
        'LongValueWithoutARecognizedPrefix1234567890'
    )
    for ($index = 0; $index -lt $unsafeSummaries.Count; $index++) {
        Write-Result (@{outcome='NO_CHANGES';reason_code='NO_CHANGE_NEEDED';summary=$unsafeSummaries[$index]} | ConvertTo-Json -Compress)
        $unsafe = Prepare "unsafe-markup-$index"
        if ($unsafe.summary -ceq $unsafeSummaries[$index] -or $unsafe.summary -cnotlike '*not published*') { throw "Unsafe summary class $index escaped sanitization." }
    }

    $long = 'x' * 1201
    Write-Result ('{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"' + $long + '"}')
    $oversize = Prepare 'long-summary'
    if ($oversize.summary -ceq $long) { throw 'Oversize summary escaped sanitization.' }

    Write-Result '{"outcome":"STOP_AND_REPORT","reason_code":"NO_CHANGE_NEEDED","summary":"one\ntwo"}'
    $multiline = Prepare 'multiline-summary'
    if ($multiline.summary -cmatch "`n") { throw 'Multiline summary escaped sanitization.' }

    Write-Result '{"outcome":"SOMETHING_ELSE","reason_code":"NO_CHANGE_NEEDED","summary":"unsafe"}'
    $malformed = Prepare 'malformed'
    if ($malformed.result -cne 'NO_CHANGES' -or $malformed.summary -cnotlike '*not published*') { throw 'Malformed model result escaped fallback.' }

    # Exercise the same publication helper with a mock GitHub provider; no
    # actual GitHub mutation or credential is involved.
    $source = Join-Path $root 'caller'
    New-Item -ItemType Directory -Path $source | Out-Null
    & git -C $source init -q
    & git -C $source -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm baseline
    $context.BaseSha = (& git -C $source rev-parse HEAD).Trim()
    Write-Result '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"No code change was required."}'
    $publishCandidate = Join-Path $root 'publish.json'
    & $helper -Action Prepare -CandidatePath $publishCandidate -ResultPath (Join-Path $root 'result.json') @context
    $mock = Join-Path $root 'gh.cmd'
    [IO.File]::WriteAllText($mock, "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0mock-gh.ps1`" %*`r`n", [Text.ASCIIEncoding]::new())
    $mockScript = @'
$route = @($args | Where-Object { $_ -like 'repos/*' })[0]
if ($route -eq 'repos/owner/repo') { '{"id":123,"full_name":"owner/repo"}'; exit 0 }
if ($route -eq 'repos/owner/repo/issues/25') {
    $issueBody = if ($env:MOCK_GH_ISSUE_BODY) { $env:MOCK_GH_ISSUE_BODY } else { 'Issue body copy' }
    @{number=25;state='open';title='Source title copy';body=$issueBody;labels=@(@{name='codex-ready'})} | ConvertTo-Json -Compress -Depth 5
    exit 0
}
if ($route -eq 'repos/owner/repo/actions/runs/567/attempts/1') { '{"id":567,"run_attempt":1,"repository":{"id":123,"full_name":"owner/repo"}}'; exit 0 }
if ($route -like 'repos/owner/repo/git/matching-refs/*') { '[]'; exit 0 }
if ($route -eq 'repos/owner/repo/pulls') { '[]'; exit 0 }
if ($route -eq 'repos/owner/repo/issues/25/comments') {
    $inputIndex = [array]::IndexOf($args, '--input')
    $request = Get-Content -LiteralPath $args[$inputIndex + 1] -Raw | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'posted-body.txt'), $request.body)
    $actorId = if ($env:MOCK_GH_ACTOR_ID) { [int]$env:MOCK_GH_ACTOR_ID } else { 41898282 }
    $issueUrl = if ($env:MOCK_GH_ISSUE_URL) { $env:MOCK_GH_ISSUE_URL } else { 'https://api.github.com/repos/owner/repo/issues/25' }
    @{id=999;body=$request.body;issue_url=$issueUrl;user=@{id=$actorId;login='github-actions[bot]';type='Bot'}} | ConvertTo-Json -Compress -Depth 5
    exit 0
}
if ($route -eq 'repos/owner/repo/issues/comments/999') {
    $body = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'posted-body.txt'))
    $actorId = if ($env:MOCK_GH_ACTOR_ID) { [int]$env:MOCK_GH_ACTOR_ID } else { 41898282 }
    $issueUrl = if ($env:MOCK_GH_ISSUE_URL) { $env:MOCK_GH_ISSUE_URL } else { 'https://api.github.com/repos/owner/repo/issues/25' }
    @{id=999;body=$body;issue_url=$issueUrl;user=@{id=$actorId;login='github-actions[bot]';type='Bot'}} | ConvertTo-Json -Compress -Depth 5
    exit 0
}
exit 1
'@
    [IO.File]::WriteAllText((Join-Path $root 'mock-gh.ps1'), $mockScript)
    $previousPath = $env:PATH
    $env:PATH = "$root;$previousPath"
    try {
        & $helper -Action Publish -CandidatePath $publishCandidate -CallerSource $source @context | Out-Null
        $body = [IO.File]::ReadAllText((Join-Path $root 'posted-body.txt'))
        if (-not $body.StartsWith("CODEX_RETURN_V1`n") -or $body -cnotmatch "`nREPOSITORY_ID=123`n" -or $body -cnotmatch "`nRESULT=NO_CHANGES`n") { throw 'Machine comment contract failed.' }
        $mismatched = $context.Clone()
        $mismatched.RepositoryId = '456'
        $mismatched.ExecutionId = 'repo-456-run-567-attempt-1'
        $blocked = $false
        try { & $helper -Action Publish -CandidatePath $publishCandidate -CallerSource $source @mismatched | Out-Null } catch { $blocked = $true }
        if (-not $blocked) { throw 'Identity mismatch did not fail closed.' }

        Write-Result '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Issue body copy"}'
        $copiedCandidate = Join-Path $root 'copied-issue.json'
        & $helper -Action Prepare -CandidatePath $copiedCandidate -ResultPath (Join-Path $root 'result.json') @context
        & $helper -Action Publish -CandidatePath $copiedCandidate -CallerSource $source @context | Out-Null
        $copiedBody = [IO.File]::ReadAllText((Join-Path $root 'posted-body.txt'))
        if ($copiedBody -clike '*SUMMARY=Issue body copy*' -or $copiedBody -cnotlike '*not published*') { throw 'Issue body was copied into the trusted comment.' }

        Write-Result '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Source title copy"}'
        $titleCandidate = Join-Path $root 'copied-title.json'
        & $helper -Action Prepare -CandidatePath $titleCandidate -ResultPath (Join-Path $root 'result.json') @context
        & $helper -Action Publish -CandidatePath $titleCandidate -CallerSource $source @context | Out-Null
        $titleBody = [IO.File]::ReadAllText((Join-Path $root 'posted-body.txt'))
        if ($titleBody -clike '*SUMMARY=Source title copy*' -or $titleBody -cnotlike '*not published*') { throw 'Issue title was copied into the trusted comment.' }

        Write-Result '{"outcome":"STOP_AND_REPORT","reason_code":"REQUIRES_USER_DECISION","summary":"Context: Issue body copy [details]"}'
        $prefixedBodyCandidate = Join-Path $root 'prefixed-body.json'
        & $helper -Action Prepare -CandidatePath $prefixedBodyCandidate -ResultPath (Join-Path $root 'result.json') @context
        & $helper -Action Publish -CandidatePath $prefixedBodyCandidate -CallerSource $source @context | Out-Null
        $prefixedBody = [IO.File]::ReadAllText((Join-Path $root 'posted-body.txt'))
        if ($prefixedBody -clike '*Issue body copy*' -or $prefixedBody -cnotlike '*not published*') { throw 'Prefixed/suffixed Issue body escaped the copy guard.' }

        Write-Result '{"outcome":"NO_CHANGES","reason_code":"NO_CHANGE_NEEDED","summary":"Summary: Source title copy"}'
        $prefixedTitleCandidate = Join-Path $root 'prefixed-title.json'
        & $helper -Action Prepare -CandidatePath $prefixedTitleCandidate -ResultPath (Join-Path $root 'result.json') @context
        & $helper -Action Publish -CandidatePath $prefixedTitleCandidate -CallerSource $source @context | Out-Null
        $prefixedTitle = [IO.File]::ReadAllText((Join-Path $root 'posted-body.txt'))
        if ($prefixedTitle -clike '*Source title copy*' -or $prefixedTitle -cnotlike '*not published*') { throw 'Prefixed Issue title escaped the copy guard.' }

        $env:MOCK_GH_ISSUE_BODY = 'Please add a harmless preview note to the existing documentation section, keeping behavior unchanged.'
        Write-Result '{"outcome":"STOP_AND_REPORT","reason_code":"REQUIRES_USER_DECISION","summary":"harmless preview note to the existing documentation section"}'
        $excerptCandidate = Join-Path $root 'body-excerpt.json'
        & $helper -Action Prepare -CandidatePath $excerptCandidate -ResultPath (Join-Path $root 'result.json') @context
        & $helper -Action Publish -CandidatePath $excerptCandidate -CallerSource $source @context | Out-Null
        $excerptBody = [IO.File]::ReadAllText((Join-Path $root 'posted-body.txt'))
        if ($excerptBody -clike '*harmless preview note to the existing documentation section*' -or $excerptBody -cnotlike '*not published*') { throw 'Substantial Issue body excerpt escaped the copy guard.' }
        Remove-Item Env:MOCK_GH_ISSUE_BODY

        $env:MOCK_GH_ACTOR_ID = '99999'
        $blocked = $false
        try { & $helper -Action Publish -CandidatePath $publishCandidate -CallerSource $source @context | Out-Null } catch { $blocked = $true }
        if (-not $blocked) { throw 'Unexpected comment actor immutable ID did not fail closed.' }
        Remove-Item Env:MOCK_GH_ACTOR_ID
        $env:MOCK_GH_ISSUE_URL = 'https://api.github.com/repos/owner/repo/issues/26'
        $blocked = $false
        try { & $helper -Action Publish -CandidatePath $publishCandidate -CallerSource $source @context | Out-Null } catch { $blocked = $true }
        if (-not $blocked) { throw 'Unexpected comment Issue URL did not fail closed.' }
        Remove-Item Env:MOCK_GH_ISSUE_URL
    } finally {
        $env:PATH = $previousPath
        Remove-Item Env:MOCK_GH_ACTOR_ID -ErrorAction SilentlyContinue
        Remove-Item Env:MOCK_GH_ISSUE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:MOCK_GH_ISSUE_BODY -ErrorAction SilentlyContinue
    }
    Write-Output 'No-PR result tests passed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
