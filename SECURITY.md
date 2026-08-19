# Security Policy

## 1. Scope

This document defines security rules for the Codex automation infrastructure.

Security boundaries must be treated as part of the architecture, not as implementation details.

## 2. auth.json

Codex `auth.json` must be treated as a high-value credential.

It MUST NOT be:

- committed to Git
- stored in the caller repository
- stored in the codex-automation repository
- printed to workflow logs
- uploaded as a normal GitHub Actions artifact
- exposed in Issue or Pull Request content

It may exist temporarily on the GitHub-hosted runner only for the duration required to execute Codex.

## 3. Secret Manager

The authoritative stored copy of each serialized Codex authentication state resides in Google Cloud Secret Manager.

Each caller repository must have a separate secret.

Example:

```text
codex-auth-interest-gacha
codex-auth-project-b
```

## 4. Repository isolation

A repository must only be authorized to access its own secret.

Example:

```text
interest-gacha
    -> codex-auth-interest-gacha
    -> allowed

interest-gacha
    -> codex-auth-project-b
    -> denied
```

IAM must enforce this boundary.

## 5. Google Cloud authentication

GitHub Actions must authenticate to Google Cloud using:

- GitHub OIDC
- Google Cloud Workload Identity Federation

Long-lived downloaded Google service account keys are not part of the architecture.

## 6. Identity claims

Authorization should prefer stable machine identity attributes.

Where practical use:

- GitHub repository ID
- repository owner ID
- trusted reusable workflow identity such as `job_workflow_ref`

Repository names alone are weaker because names may change or be reused.

## 7. Runner policy

Only GitHub-hosted runners are used in the initial architecture.

The runner must be treated as ephemeral.

Sensitive files should be removed or allowed to disappear with the runner at job completion.

## 8. Authentication concurrency

A single `auth.json` must never be actively used by multiple parallel Codex jobs.

Therefore:

```text
1 serialized workflow stream
    =
1 auth.json
```

Jobs sharing the same authentication state must execute serially.

## 9. Secret version update

Codex may update authentication state while running.

Before execution, the automation records whether `auth.json` changes.

After execution:

- unchanged auth -> do not create a new secret version
- changed auth -> create a new secret version

A new secret version must be verified before the previous version is retired.

## 10. Secret retirement

The safe sequence is conceptually:

```text
current version
    ↓
Codex
    ↓
new version
    ↓
verify new version
    ↓
disable previous version
    ↓
later cleanup / destroy
```

Permanent destruction must not happen merely because an upload command returned success.

## 11. Logging

Logs must be useful for debugging without exposing credentials.

Logs may contain:

- execution phase
- caller repository identity
- Issue number
- branch name
- commit SHA
- status
- sanitized error category

Logs must not contain:

- raw `auth.json`
- refresh tokens
- access tokens
- secret payloads
- Google credentials

## 12. Least privilege

Every component should receive only the permissions it needs.

This applies to:

- GitHub `GITHUB_TOKEN`
- Google Cloud IAM
- Secret Manager
- OIDC trust conditions
- reusable workflow permissions

Permission expansion should require an explicit reason.

## 13. Public repository

`codex-automation` may be public.

No secret, repository-specific credential, user authentication state, or sensitive infrastructure value may depend on repository privacy for protection.

The design should remain safe even when all source code and documentation in this repository are publicly readable.
