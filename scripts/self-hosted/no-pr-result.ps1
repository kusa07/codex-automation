param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Publish')][string]$Action,
    [Parameter(Mandatory)][string]$CandidatePath,
    [string]$ResultPath,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$RepositoryId,
    [Parameter(Mandatory)][string]$IssueNumber,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$RunAttempt,
    [Parameter(Mandatory)][string]$ExecutionId,
    [Parameter(Mandatory)][string]$OwnerNonce,
    [Parameter(Mandatory)][string]$BaseSha,
    [string]$CallerSource
)

$ErrorActionPreference = 'Stop'
$SafeFallback = 'Codex completed without publishable repository changes. The detailed model message was not published because it did not pass the trusted result sanitization policy.'
$AllowedReasons = @('NO_CHANGE_NEEDED', 'INSUFFICIENT_VERIFIABLE_INPUT', 'REQUIRES_USER_DECISION', 'BLOCKED_BY_ENVIRONMENT', 'REPOSITORY_STATE_CONFLICT', 'OTHER_SAFE_STOP')

function Assert-Context {
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $RepositoryId -notmatch '^[1-9][0-9]*$' -or $IssueNumber -notmatch '^[1-9][0-9]*$' -or
        $RunId -notmatch '^[1-9][0-9]*$' -or $RunAttempt -notmatch '^[1-9][0-9]*$' -or
        $ExecutionId -cne "repo-$RepositoryId-run-$RunId-attempt-$RunAttempt" -or
        $OwnerNonce -cnotmatch '^[0-9a-f]{32}$' -or $BaseSha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Invalid trusted no-PR execution context.'
    }
}

function Assert-PlainFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw 'Expected a regular non-reparse file.'
    }
    return $item
}

function Test-SafeSummary([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 1200 -or
        $Text -match '[\x00-\x1f\x7f\u0085\u2028\u2029]' -or
        $Text -match '(?i)(https?://|www\.|mailto:|\bsk-[a-z0-9_-]{8,})' -or
        $Text -match '[<>&@\[\](){}`*_#~|\\]' -or $Text -match '^\s*[-+]\s+' -or
        $Text -match '(?i)\b(?:tokens?|secrets?|passwords?|credentials?|authentication|authorization|auth|keys?|private|bearer|oauth)\b' -or
        $Text -cmatch '(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{24,}(?![A-Za-z0-9_-])' -or
        $Text -cmatch '(?i)\b(?:AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{8,})\b' -or
        $Text -match '(?i)(auth\.json|private[ -]?key|begin [a-z ]*private key|bearer\s+\S+|password\s*[:=]|secret\s*[:=]|api[_ -]?key\s*[:=]|access[_ -]?token\s*[:=]|refresh[_ -]?token\s*[:=]|github_pat_[a-z0-9_]+|gh[pousr]_[a-z0-9]+|ya29\.[a-z0-9._-]+|AIza[a-z0-9_-]+|CODEX_RETURN_V1|```|\{\s*"?tokens?"?\s*:)' -or
        $Text -cmatch '(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})(?![0-9A-Fa-f])' -or
        $Text -cmatch '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b') {
        return $false
    }
    return $true
}

function Test-IssueTextCopy([string]$Summary, [string]$IssueText) {
    $needle = ($IssueText -replace '\s+', ' ').Trim()
    if ($needle.Length -eq 0) { return $false }
    $haystack = ($Summary -replace '\s+', ' ').Trim()
    if ($needle.Length -lt 8) { return $haystack.Equals($needle, [StringComparison]::OrdinalIgnoreCase) }
    if ($haystack.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    # A bounded model summary can quote just part of a longer untrusted Issue.
    # Search every substantial summary window against the authoritative text;
    # safe false positives only select the fixed fallback message.
    if ($needle.Length -ge 24 -and $haystack.Length -ge 24) {
        for ($offset = 0; $offset -le $haystack.Length - 24; $offset++) {
            if ($needle.IndexOf($haystack.Substring($offset, 24), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }
    return $false
}

function Read-JsonObject([string]$Path, [int]$MaximumBytes) {
    $item = Assert-PlainFile $Path
    if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) { throw 'Invalid bounded JSON file size.' }
    $content = [IO.File]::ReadAllText($item.FullName, [Text.Encoding]::UTF8)
    $parsed = ConvertFrom-Json -InputObject $content -AsHashtable -ErrorAction Stop
    if ($parsed -isnot [System.Collections.IDictionary]) { throw 'Expected JSON object.' }
    return $parsed
}

function Invoke-GhJson([string[]]$Arguments) {
    $output = & gh api @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Authoritative GitHub read or comment write failed.' }
    $parsed = ConvertFrom-Json -InputObject ($output -join "`n") -AsHashtable -ErrorAction Stop
    return ,$parsed
}

Assert-Context

if ($Action -eq 'Prepare') {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { throw 'Result path is required.' }
    if (Test-Path -LiteralPath $CandidatePath -PathType Any) { throw 'No-PR candidate already exists.' }
    $result = 'NO_CHANGES'
    $reason = 'OTHER_SAFE_STOP'
    $summary = $SafeFallback
    try {
        $model = Read-JsonObject $ResultPath 16384
        if (@($model.Keys).Count -ne 3 -or
            -not $model.Contains('outcome') -or -not $model.Contains('reason_code') -or -not $model.Contains('summary')) {
            throw 'Structured outcome fields are invalid.'
        }
        if ($model.outcome -cnotin @('IMPLEMENTED','NO_CHANGES','STOP_AND_REPORT') -or
            $model.reason_code -cnotin (@('IMPLEMENTED') + $AllowedReasons) -or
            $model.summary -isnot [string]) { throw 'Structured outcome values are invalid.' }
        if ($model.outcome -ceq 'STOP_AND_REPORT' -and $model.reason_code -cin $AllowedReasons) {
            $result = 'STOP_AND_REPORT'
            $reason = [string]$model.reason_code
        } elseif ($model.outcome -ceq 'NO_CHANGES' -and $model.reason_code -cin $AllowedReasons) {
            $reason = [string]$model.reason_code
        }
        # Actual validated zero-change state outranks an IMPLEMENTED claim.
        if ($model.outcome -cne 'IMPLEMENTED' -and (Test-SafeSummary ([string]$model.summary))) {
            $summary = [string]$model.summary
        }
    } catch {
        # Malformed or unsafe model output never becomes a comment or a log.
        $result = 'NO_CHANGES'
        $reason = 'OTHER_SAFE_STOP'
        $summary = $SafeFallback
    }
    $candidate = [ordered]@{
        schema = 1
        repository = $Repository
        repository_id = $RepositoryId
        issue_number = $IssueNumber
        run_id = $RunId
        run_attempt = $RunAttempt
        execution_id = $ExecutionId
        owner_nonce = $OwnerNonce
        base_sha = $BaseSha
        result = $result
        reason_code = $reason
        next_action = 'USER_REVIEW'
        summary = $summary
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($CandidatePath, (ConvertTo-Json -InputObject $candidate -Compress -Depth 4), $utf8)
    Assert-PlainFile $CandidatePath | Out-Null
    exit 0
}

if ([string]::IsNullOrWhiteSpace($CallerSource)) { throw 'Caller checkout path is required.' }
$candidate = Read-JsonObject $CandidatePath 4096
if (@($candidate.Keys).Count -ne 13 -or
    $candidate.schema -ne 1 -or
    [string]$candidate.repository -cne $Repository -or
    [string]$candidate.repository_id -cne $RepositoryId -or
    [string]$candidate.issue_number -cne $IssueNumber -or
    [string]$candidate.run_id -cne $RunId -or
    [string]$candidate.run_attempt -cne $RunAttempt -or
    [string]$candidate.execution_id -cne $ExecutionId -or
    [string]$candidate.owner_nonce -cne $OwnerNonce -or
    [string]$candidate.base_sha -cne $BaseSha -or
    $candidate.result -cnotin @('NO_CHANGES','STOP_AND_REPORT') -or
    $candidate.reason_code -cnotin $AllowedReasons -or
    $candidate.next_action -cne 'USER_REVIEW' -or
    $candidate.summary -isnot [string] -or
    -not (Test-SafeSummary ([string]$candidate.summary))) {
    throw 'No-PR candidate context or content failed validation.'
}
$checkout = Get-Item -LiteralPath $CallerSource -Force
if (-not $checkout.PSIsContainer -or $checkout.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Caller checkout is invalid.'
}
$localSha = & git -C $CallerSource rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or $localSha -cne $BaseSha) { throw 'Caller checkout base SHA changed.' }
$localStatus = & git -C $CallerSource status --porcelain=v1 --untracked-files=all 2>$null
if ($LASTEXITCODE -ne 0 -or @($localStatus).Count -ne 0) { throw 'Caller checkout is not clean.' }

$repo = Invoke-GhJson @("repos/$Repository")
if ([string]$repo.id -cne $RepositoryId -or [string]$repo.full_name -cne $Repository) { throw 'Repository immutable identity mismatch.' }
$issue = Invoke-GhJson @("repos/$Repository/issues/$IssueNumber")
if ([string]$issue.number -cne $IssueNumber -or $issue.state -cne 'open' -or $issue.Contains('pull_request') -or
    -not (@($issue.labels | ForEach-Object { $_.name }) -contains 'codex-ready')) {
    throw 'Source Issue identity or authorization changed.'
}
$safeSummary = [string]$candidate.summary
if ((Test-IssueTextCopy $safeSummary ([string]$issue.title)) -or
    (Test-IssueTextCopy $safeSummary ([string]$issue.body))) {
    # The source Issue is untrusted task data, not safe user-facing output.
    $safeSummary = $SafeFallback
}
$run = Invoke-GhJson @("repos/$Repository/actions/runs/$RunId/attempts/$RunAttempt")
if ([string]$run.id -cne $RunId -or [string]$run.run_attempt -cne $RunAttempt -or
    [string]$run.repository.id -cne $RepositoryId -or [string]$run.repository.full_name -cne $Repository) {
    throw 'Workflow execution identity mismatch.'
}
$branch = "codex/issue-$IssueNumber-run-$RunId-attempt-$RunAttempt"
$encodedBranch = [uri]::EscapeDataString($branch)
$refs = Invoke-GhJson @("repos/$Repository/git/matching-refs/heads/$encodedBranch")
if (@($refs).Count -ne 0) { throw 'Task branch already exists remotely.' }
$owner = $Repository.Split('/')[0]
$pulls = Invoke-GhJson @('--method','GET',"repos/$Repository/pulls",'-f','state=all','-f',"head=${owner}:$branch")
if (@($pulls).Count -ne 0) { throw 'Task Pull Request already exists.' }

$body = @(
    'CODEX_RETURN_V1'
    "REPOSITORY=$Repository"
    "REPOSITORY_ID=$RepositoryId"
    "ISSUE_NUMBER=$IssueNumber"
    "RUN_ID=$RunId"
    "RUN_ATTEMPT=$RunAttempt"
    "RESULT=$($candidate.result)"
    "REASON_CODE=$($candidate.reason_code)"
    'NEXT_ACTION=USER_REVIEW'
    "SUMMARY=$safeSummary"
) -join "`n"
$requestPath = "$CandidatePath.request"
if (Test-Path -LiteralPath $requestPath -PathType Any) { throw 'No-PR request path already exists.' }
try {
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($requestPath, (ConvertTo-Json -InputObject @{body=$body} -Compress), $utf8)
    $created = Invoke-GhJson @('--method','POST',"repos/$Repository/issues/$IssueNumber/comments",'--input',$requestPath)
    $expectedIssueUrl = "https://api.github.com/repos/$Repository/issues/$IssueNumber"
    if ([string]$created.id -notmatch '^[1-9][0-9]*$' -or $created.body -cne $body -or
        $created.issue_url -cne $expectedIssueUrl -or
        [string]$created.user.id -cne '41898282' -or $created.user.type -cne 'Bot' -or
        $created.user.login -cne 'github-actions[bot]') {
        throw 'Created Issue comment response was invalid.'
    }
    $readback = Invoke-GhJson @("repos/$Repository/issues/comments/$($created.id)")
    if ([string]$readback.id -cne [string]$created.id -or $readback.body -cne $body -or
        $readback.issue_url -cne $expectedIssueUrl -or
        [string]$readback.user.id -cne '41898282' -or $readback.user.type -cne 'Bot' -or
        $readback.user.login -cne 'github-actions[bot]') {
        throw 'Created Issue comment authoritative read-back failed.'
    }
    Write-Output "Trusted no-PR Issue comment created: $($created.id)"
} finally {
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
}
