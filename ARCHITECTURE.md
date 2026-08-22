# Architecture

## 1. Purpose

`codex-automation` provides a common execution platform for running Codex across multiple GitHub repositories.

The central design principle is separation of concerns:

```text
Application repository
    = WHAT to build

codex-automation
    = HOW Codex is executed

Google Cloud
    = HOW Codex credentials are securely stored
```

The shared layer must prevent individual projects from needing to understand or duplicate the internal authentication and Codex execution mechanism.

## 2. High-level architecture

```text
User
  ↕
ChatGPT
  ↕
GitHub Issue
  |
  | codex-ready
  v
Caller Workflow
  |
  v
codex-automation Reusable Workflow
  |
  +--> GitHub-hosted runner
  |
  +--> GitHub OIDC
  |       |
  |       v
  |    Google Cloud
  |       |
  |       +--> Workload Identity Federation
  |       |
  |       +--> Secret Manager
  |
  +--> Codex CLI
  |
  v
Project branch
  |
  v
Pull Request
  |
  v
Human / ChatGPT review
```

## 3. Components

### 3.1 User

The user remains the authority for:

- deciding what should be implemented
- approving work before Codex execution when appropriate
- reviewing results
- deciding whether a Pull Request should be merged

Automation must not redefine user approval semantics.

### 3.2 ChatGPT

ChatGPT acts as the front-facing planning and orchestration interface.

Its responsibilities may include:

- discussing requirements with the user
- turning requirements into actionable GitHub Issues
- reviewing Issues before they become `codex-ready`
- interpreting Codex results
- reviewing Pull Requests
- comparing new implementation proposals against recorded project decisions

ChatGPT does not need direct knowledge of Codex authentication internals.

### 3.3 Caller repository

A caller repository is an application repository such as `interest-gacha`.

It owns:

- source code
- project requirements
- Issues
- Pull Requests
- project-specific Codex instructions
- `AGENTS.md`
- project architecture
- project-specific decisions

It contains only the minimum integration required to invoke `codex-automation`.

### 3.4 codex-automation

The shared repository owns:

- reusable GitHub Actions workflows
- authentication restore and persistence lifecycle
- Codex setup and execution
- execution serialization
- validation
- security controls
- error handling
- shared development protocol

It must not contain application-specific architecture.

### 3.5 GitHub Actions

GitHub Actions provides the automation execution environment.

Only GitHub-hosted runners are used.

Self-hosted runners are explicitly outside the initial architecture.

### 3.6 Google Cloud

A dedicated Google Cloud Project named for `codex-automation` is used for the authentication infrastructure.

Its responsibilities include:

- Workload Identity Federation
- GitHub OIDC trust
- IAM
- Secret Manager
- Codex `auth.json` version management

### 3.7 Codex CLI

Codex CLI performs implementation work inside the caller repository checkout.

The intended authentication model uses ChatGPT authentication rather than a separately billed OpenAI API key.

## 4. Authentication architecture

Each caller repository receives a separate Secret Manager secret.

Example:

```text
codex-auth-interest-gacha
codex-auth-project-b
codex-auth-project-c
```

A single `auth.json` must belong to a single serialized execution stream.

The same `auth.json` must not be used concurrently by multiple Codex jobs.

Authentication flow:

```text
GitHub Actions
    |
    | OIDC token
    v
Google Cloud Workload Identity Federation
    |
    | authorized repository identity
    v
Secret Manager
    |
    v
auth.json
    |
    v
Codex CLI
```

No long-lived Google Cloud service account key should be required.

## 5. Secret lifecycle

Before Codex execution:

1. Authenticate GitHub Actions to Google Cloud through OIDC / WIF.
2. Retrieve the caller repository's `auth.json`.
3. Store it only in the ephemeral runner environment.
4. Calculate or otherwise record whether the file changes during execution.

After Codex execution:

1. Check whether `auth.json` changed.
2. If unchanged, create no new Secret Manager version.
3. If changed, treat the changed file as a candidate authentication state and create a new secret version.
4. Verify both that the candidate version was stored correctly and that it is a usable authentication state.
5. Only after successful validation, adopt the candidate as the next authoritative authentication state and disable the previous version.
6. If validation fails, keep the previous version enabled, do not destroy it, and do not report the job as successful.
7. Destroy old versions only according to a separately defined safe retention / cleanup policy.

A changed file and a valid new authentication state are separate conditions. A changed `auth.json` must not be adopted unconditionally, including when Codex exits abnormally.

Immediate irreversible destruction is intentionally avoided.

## 6. Serialization

Codex execution is serialized within each caller repository.

Conceptually:

```text
interest-gacha Codex queue

Issue A
  ↓
Issue B
  ↓
Issue C
```

Separate caller repositories may have separate serialized streams and separate `auth.json` secrets.

Runs within one caller repository form a queue and are processed one at a time. A new run must not simply replace or cancel a Codex job already in progress. The implementation is expected to use GitHub Actions concurrency / queue behavior, with `cancel-in-progress`-equivalent behavior disabled by default for the Codex execution stream. The exact YAML syntax will be decided during implementation.

This prevents multiple jobs from mutating or refreshing the same authentication state simultaneously, and avoids interrupting authentication or branch updates in a way that could leave inconsistent state.

## 7. Reusable workflow architecture

The final implementation is expected to expose a reusable GitHub Actions workflow from `codex-automation`.

Caller repositories should invoke that workflow through a versioned, controlled reference. The default policy is to pin the reusable workflow to an immutable commit SHA rather than follow a branch implicitly. When `codex-automation` changes, each caller deliberately updates its pinned SHA so that breaking changes are not adopted automatically. A release or tag-based process may be introduced later.

Caller repositories should contain only a thin adapter responsible for:

- detecting or reacting to `codex-ready`
- passing allowed caller context
- invoking the shared workflow

The caller must not duplicate:

- Google authentication logic
- Secret Manager restore logic
- auth persistence logic
- Codex installation internals
- common validation
- shared security behavior

## 8. Trust boundary

Authorization should identify not only the caller repository but, where practical, the specific shared reusable workflow being used.

Potential identity attributes include:

- immutable GitHub repository ID
- repository owner ID
- `job_workflow_ref`
- other stable GitHub OIDC claims

Repository names alone should not be the only trust mechanism when stronger immutable identifiers are available.

## 9. Design principle

The most important architectural rule is:

> Application repositories should know how to request Codex execution, but should not need to know how Codex authentication and execution infrastructure works.

## 10. Phase 9 Issue task path

The Phase 9 read-only execution path is:

```text
open GitHub Issue
    ↓ codex-ready label
thin caller workflow
    ↓ issue_number
codex-automation reusable workflow
    ↓ GitHub API read-back and validation
runner-local validated task file
    ↓
Codex CLI in read-only mode
```

The caller passes only Issue identity and fixed infrastructure inputs. The shared workflow retrieves the Issue from the caller repository and verifies that it is an open Issue, is not a Pull Request, has the `codex-ready` label, and has usable title and body content before Codex can run.

Issue title and body are untrusted task input. They cannot change workflow permissions, authentication handling, Secret selection, credential logging rules, or the read-only sandbox. The validated content is written to a protected runner-local file and supplied to Codex as data rather than evaluated by the shell.

Phase 9 ends at read-only task analysis. Repository writes, branches, commits, pushes, and Pull Requests remain Phase 10 responsibilities.
