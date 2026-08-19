# CONTRACT.md

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

## 3. codex-automation responsibilities

`codex-automation` MUST own:

- Codex execution orchestration
- GitHub-hosted runner usage
- Google Cloud authentication flow
- Secret Manager access
- `auth.json` restoration
- `auth.json` persistence
- serialization
- common security controls
- common error handling
- common execution logging rules

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

Changes to the internal authentication mechanism should not normally require changes in every caller repository.

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

## 7. Inputs

The exact reusable workflow schema is intentionally not fixed in this design version.

Likely caller inputs may include:

- issue identifier
- repository context
- task metadata
- approved Codex execution options

Infrastructure details such as raw `auth.json`, Google credentials, or Secret Manager implementation details must not be passed from the application repository as ordinary workflow data.

## 8. Outputs

Likely outputs from the shared automation may include:

- execution status
- resulting branch
- commit identifiers
- Pull Request identifier
- failure classification

The exact output contract will be defined during implementation design.

## 9. Versioning

Caller repositories should invoke a versioned or otherwise controlled release of the reusable workflow.

Caller repositories should not unintentionally consume arbitrary breaking changes from the shared repository.

The concrete versioning mechanism will be decided during workflow implementation.

## 10. Non-goals

The contract does not require `codex-automation` to know:

- application domain logic
- project-specific coding conventions beyond supplied project instructions
- project-specific product decisions
- project-specific historical decisions

Those remain caller responsibilities.
