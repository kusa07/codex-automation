# Caller Contract

## 1. Purpose

This document defines the boundary between:

- caller repositories
- `codex-automation`

The contract exists so that application repositories remain loosely coupled to the internal implementation of the shared automation layer.

## 2. Caller responsibilities

A caller repository MUST own:

- the work request
- GitHub Issue content
- project-specific instructions
- source code
- tests
- application-specific validation requirements
- project-specific architecture
- project-specific decision history

A caller repository SHOULD provide project-specific Codex guidance through mechanisms such as `AGENTS.md`.

The caller workflow is also responsible for explicitly declaring the GitHub Actions permissions required by the reusable workflow. In Phase 9 these are `contents: read`, `issues: read`, and `id-token: write`. A reusable workflow cannot elevate permissions beyond those granted by its caller.

In Phase 10 the required caller permissions are `contents: write`,
`issues: read`, `pull-requests: write`, and `id-token: write`. The write
permissions exist only for trusted task-branch publication and Draft Pull
Request creation.

A caller may need to expose runner eligibility or binding required by GitHub's runner resource model, but that does not transfer ownership of Self-hosted Execution policy or lifecycle into the caller repository.

## 3. codex-automation responsibilities

`codex-automation` MUST own:

- Codex execution orchestration
- execution backend orchestration
- GitHub-hosted runner usage for the validated hosted path
- approved Self-hosted Execution lifecycle and policy
- Self-hosted Execution Area desired state, preflight, locking, cleanup, and recovery rules
- Google Cloud authentication flow
- Secret Manager access
- `auth.json` restoration
- `auth.json` persistence
- serialization
- common security controls
- common error handling
- common execution logging rules

The caller repository must not duplicate or become the source of truth for:

- local execution-area structure
- automation Codex runtime isolation
- local credential lifecycle
- local execution locking
- Self-hosted Execution cleanup or residual-state policy
- Self-hosted Execution migration policy

## 4. Thin caller principle

The caller workflow should be intentionally small.

Conceptually:

```text
GitHub Issue
  |
  | codex-ready
  v
caller workflow
  |
  | minimal inputs
  v
codex-automation reusable workflow
```

Changes to the internal authentication or execution mechanism should not normally require changes in every caller repository.

Being thin means that the caller does not duplicate shared business or infrastructure logic. It does not remove the caller's responsibility to provide an explicit, minimal GitHub permission boundary required for the shared workflow to operate.

For Self-hosted Execution, the caller requests work and may participate in GitHub runner eligibility as required by the platform. `codex-automation` remains responsible for execution policy, local lifecycle, credential handling, and trusted publication behavior.

## 5. Expected caller identity

Every caller must have a distinct identity and a distinct Secret Manager credential boundary.

Example:

```text
interest-gacha
    -> codex-auth-interest-gacha

project-b
    -> codex-auth-project-b
```

A caller must never be authorized to read or modify another caller's Codex authentication secret.

## 6. Authentication isolation

The implementation must enforce repository-level isolation.

Where practical, authorization should use stable GitHub identity claims rather than only human-readable repository names.

The shared workflow identity should also be validated where possible.

Self-hosted execution must preserve the same caller boundary for authentication state and must not allow one caller to inherit another caller's workspace, runtime, temporary credential, task, or publication state.

## 7. Inputs

The Phase 9 reusable workflow contract requires:

- `issue_number`
  - numeric identity of the Issue in the caller repository
- `google_cloud_project_id`
  - Google Cloud Project containing the caller-specific Secret
- `workload_identity_provider`
  - full resource name of the trusted Workload Identity Provider

The caller detects an Issue `labeled` event, verifies that the added label is `codex-ready`, and passes the Issue number. It does not pass the Issue title or body as ordinary workflow inputs.

The shared workflow retrieves the Issue from the caller repository and validates that it exists, is open, is not a Pull Request, retains the `codex-ready` label, and has non-empty title and body content. A validation failure is fail-closed and must occur before Codex execution.

Infrastructure details such as raw `auth.json`, Google credentials, Secret Manager implementation details, Self-hosted Execution directory paths, local lock state, or local Codex runtime details must not be passed from the application repository as ordinary workflow data.

Phase 10 does not introduce an `executor`, `runner_profile`, or equivalent caller input merely to support the first Self-hosted / Local Codex path. Executor abstraction remains a future concern unless separately approved.

## 8. Outputs

Likely outputs from the shared automation may include:

- execution status
- resulting branch
- commit identifiers
- Pull Request identifier
- failure classification

Phase 9 produces a read-only Codex task analysis in sanitized workflow output. Branch, commit, and Pull Request outputs are not part of the Phase 9 contract.

Self-hosted runner availability or local preflight failures should ultimately be distinguishable from Codex implementation failures, but the detailed result classification belongs primarily to Phase 11.

## 9. Versioning

Caller repositories should invoke the reusable workflow through a versioned or otherwise controlled reference.

The default policy is to pin the workflow reference to an immutable commit SHA. Branch references that implicitly follow updates are not the normal operating model. When `codex-automation` is updated, each caller repository should deliberately update its referenced SHA so that it does not automatically consume a breaking change.

A release or tag-based process may be introduced later, and its exact mechanics will be decided during workflow implementation.

## 10. Non-goals

The contract does not require `codex-automation` to know:

- application domain logic
- project-specific coding conventions beyond supplied project instructions
- project-specific product decisions
- project-specific historical decisions

Those remain caller responsibilities.

The caller contract also does not require caller repositories to understand or duplicate the internals of the Self-hosted Execution Area.

## 11. Phase 10 publication contract

The caller remains a thin adapter. It passes the Issue number and fixed Google
Cloud infrastructure inputs and grants the minimum required GitHub
permissions. It does not implement branch naming, repository validation,
Self-hosted Execution lifecycle, commit, push, or Pull Request logic.

The shared workflow / trusted automation:

- resolves and validates the caller repository's current default branch
- performs or gates the approved Self-hosted Execution path
- creates the deterministic task branch
- gives Codex write access only to the working tree
- keeps GitHub publication credentials outside the Codex process
- validates the implementation before staging
- creates one fixed-author implementation commit
- pushes only the generated task branch
- creates one Draft Pull Request

Issue title and body are not used as branch names, commit messages, or Pull
Request titles. Existing task branches or Pull Requests cause fail-closed
behavior rather than update or overwrite.

GitHub runner resource binding, when required in caller context, is a platform eligibility detail. It does not make the caller responsible for Self-hosted Execution security, lifecycle, or publication policy.
