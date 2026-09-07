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

It may exist temporarily only inside an approved automation-managed execution environment and only for the duration required by the execution lifecycle.

For Self-hosted Execution, `auth.json` must be confined to the credential/runtime locations defined by `SELF_HOSTED_EXECUTION.md`. The persistent local machine must not make the local copy authoritative, and the normal user Codex runtime must not be used by default.

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

Self-hosted execution must also preserve caller isolation for workspaces, temporary files, Codex runtime state, execution state, and publication state.

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

## 7. Runner and execution-environment policy

The validated execution path through Phase 9 uses GitHub-hosted ephemeral runners.

Phase 10 write-capable execution uses the approved Self-hosted Execution architecture defined in `SELF_HOSTED_EXECUTION.md`.

A self-hosted machine is a persistent security boundary. State may survive after a job even when cleanup was expected to run.

Therefore Self-hosted Execution must use:

- an explicit `codex-automation` managed execution area outside normal user repositories
- an isolated automation Codex runtime rather than the user's normal Codex home by default
- pre-job managed-area and residual-state validation
- post-job cleanup and residual-state validation
- a local execution lock in addition to GitHub Actions concurrency
- bounded credential locations
- fail-closed behavior for ambiguous or inconsistent state
- explicit schema/version handling for the managed execution area

An unknown existing execution directory, unreadable or invalid management marker, unsupported schema, abandoned execution state, unexpected credential residue, or other security-relevant ambiguity must not be silently repaired during normal execution.

## 8. Authentication concurrency

A single `auth.json` must never be actively used by multiple parallel Codex jobs.

Therefore:

```text
1 serialized workflow stream
    =
1 auth.json
```

Jobs sharing the same authentication state must execute serially.

For the initial Self-hosted Execution implementation, one managed execution area may run only one job at a time. GitHub Actions concurrency protects the caller/authentication stream; the local execution lock protects the persistent host execution area. Neither replaces the other.

## 9. Secret version update

Codex may update authentication state while running.

At normal run start, exactly one Secret Manager version must be enabled. Zero enabled versions or multiple enabled versions are ambiguous states and must fail closed. The workflow records the numeric authoritative version ID and reads that exact version; it must not select the authoritative state through `latest`.

Before execution, the automation records a SHA-256 digest of `auth.json` without logging the credential or its digest.

After execution:

- unchanged auth -> do not create a new secret version
- changed auth -> treat it as a candidate authentication state and create a candidate secret version

A change and a usable new authentication state are separate determinations. The candidate version must be verified after storage and adopted as the next authoritative state only when validation succeeds. This rule also applies when Codex exits abnormally; a changed file must not be accepted unconditionally.

Validation requires all of the following:

- the changed local file is recognized by `codex login status` as a ChatGPT login
- the exact candidate version can be read back
- the read-back bytes match the local candidate
- the stored candidate is recognized by Codex as a ChatGPT login

If validation fails before adoption, the previous version must remain enabled and must not be destroyed. A created but unadopted candidate should be disabled when possible, and the job must not report success.

Secret payloads, `auth.json`, and comparison hashes must not be printed or passed through workflow outputs. Runtime handling does not destroy Secret versions.

## 10. Secret retirement

The safe sequence is conceptually:

```text
current version
    ↓
Codex
    ↓
changed auth.json
    ↓
candidate version
    ↓
validate candidate
    ↓
adopt as authoritative state
    ↓
disable previous version
    ↓
later cleanup / destroy
```

If candidate validation fails, the previous version remains authoritative and enabled; it is neither disabled nor destroyed, and the failure is reported.

Only after the candidate passes local, storage, byte-equivalence, and stored-authentication validation may the previous authoritative version be disabled. The workflow must then verify that exactly one enabled version remains and that it is the adopted candidate.

An interrupted workflow may leave multiple versions enabled. A later run must fail closed at preflight rather than guess, automatically select `latest`, or attempt automatic repair. Recovery requires explicit operational review.

Permanent destruction must not happen merely because an upload command returned success.

## 11. Logging and auditability

Logs must be useful for debugging without exposing credentials.

Logs may contain:

- execution phase
- caller repository identity
- Issue number
- branch name
- commit SHA
- execution ID
- sanitized lifecycle event
- status
- sanitized error category

Logs must not contain:

- raw `auth.json`
- refresh tokens
- access tokens
- secret payloads
- Google credentials

For Self-hosted Execution, security-relevant lifecycle events such as execution start, preflight result, credential restoration, Codex start/finish, credential removal, cleanup result, abandoned-lock detection, and fail-closed activation should be emitted in sanitized form to GitHub Actions logs.

Local logs are supplementary operational diagnostics and must not be the only audit trail for security-relevant execution events.

## 12. Least privilege

Every component should receive only the permissions it needs.

This applies to:

- GitHub `GITHUB_TOKEN`
- Google Cloud IAM
- Secret Manager
- OIDC trust conditions
- reusable workflow permissions
- local filesystem access used by Self-hosted Execution

Permission expansion should require an explicit reason.

## 13. Public repository

`codex-automation` may be public.

No secret, repository-specific credential, user authentication state, or sensitive infrastructure value may depend on repository privacy for protection.

The design should remain safe even when all source code and documentation in this repository are publicly readable.

## 14. Phase 10 GitHub publication boundary

Codex must not receive a GitHub write token. Checkout uses
`persist-credentials: false`, and Google credential files are removed before
Codex execution. GitHub and OIDC credential environment variables are removed
from the Codex subprocess environment.

GitHub tokens are provided only to the individual metadata, push, and Pull
Request steps that require them. Tokens must not be stored in repository
remotes, command-line arguments, Git configuration, workflow outputs, or
runner-local helper file contents.

Git push uses a temporary `GIT_ASKPASS` helper. The helper reads the step-local
token from its environment and returns it through Git's credential channel.
Terminal prompting and inherited credential helpers are disabled, the push
uses an explicit generated-branch refspec, and the helper is removed by a
trap.

Codex is prohibited from creating commits, staged changes, branches, tags,
remotes, or Git configuration changes. Before publication, the workflow
verifies the expected branch and base commit, empty staged state, unchanged
repository-local Git configuration, unchanged origin URL, and unchanged refs.

Changes to workflow files, local Actions, AGENTS.md, Git control files, and
known credential-like paths are rejected. Symlinks and gitlinks are also
rejected before and after staging. An exact copy of both the pre-Codex
authoritative auth material and the current auth.json is rejected without
printing contents or hashes.

These checks are a restricted publication policy and known credential-artifact
check. They are not a general secret scanner and do not claim to detect every
possible secret.

The workflow never pushes directly to the trusted default branch, never force
pushes, and creates only a Draft Pull Request. It does not approve, mark ready,
or merge the Pull Request automatically.

## 15. Self-hosted threat model

Self-hosted Execution assumes a trusted Windows PC administered by the user.

The `codex-automation` security model is intended to reduce risks such as:

- unauthorized or malformed GitHub-triggered execution reaching Codex
- cross-caller state contamination
- stale credential residue in known automation-managed locations
- interrupted executions leaving ambiguous state
- unexpected workspace reuse
- duplicate or concurrent execution inside the managed execution area

The following are outside the guarantee of `codex-automation` itself:

- a malicious local administrator
- malware, rootkit, or operating-system compromise
- a fully compromised trusted host
- forensic recovery of deleted credential data from storage media
- physical compromise of an unlocked or running machine

Host hardening such as disk encryption may be recommended operationally, but Phase 10 does not claim to make an already-compromised host trustworthy.

Credential handling therefore relies on restricting where sensitive files may be written, limiting their lifetime, deleting them after use, and verifying the known managed locations before and after execution. The design does not claim forensic secure erasure on SSD or other storage media.
