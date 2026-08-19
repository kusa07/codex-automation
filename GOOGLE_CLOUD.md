# Google Cloud Architecture

## 1. Purpose

This document defines the v0.1 Google Cloud design for authentication, Secret Manager lifecycle, and IAM isolation used by `codex-automation`.

It covers only the shared infrastructure used to protect and operate Codex authentication state. It does not define or host application-specific Google Cloud resources.

## 2. Design principles

- one shared Google Cloud Project
- one shared Workload Identity Pool
- one shared GitHub OIDC Provider
- repository-level Secret isolation
- direct federated resource access
- no long-lived service account keys
- least privilege
- immutable GitHub identity claims where practical

## 3. High-level structure

Google Cloud structure:

```text
Google Cloud Project
└─ codex-automation
   ├─ Workload Identity Pool
   │  └─ github
   │     └─ OIDC Provider
   │        └─ github-actions
   └─ Secret Manager
      ├─ codex-auth-interest-gacha
      ├─ codex-auth-project-b
      └─ codex-auth-project-c
```

Repository access flow:

```text
kusa07/interest-gacha
    ↓ GitHub OIDC
Workload Identity Provider
    ↓ repository identity validation
Federated principal
    ↓ Secret-level IAM
codex-auth-interest-gacha
```

## 4. Google Cloud Project

The design uses one Google Cloud Project dedicated to the Codex authentication infrastructure.

The conceptual project name is `codex-automation`. Because a Google Cloud Project ID must be globally unique, implementation will select an available unique ID rather than assuming this conceptual name is available.

Application workloads and application-specific infrastructure are not placed in this project.

## 5. Workload Identity Pool

One shared Workload Identity Pool is used.

Recommended pool ID:

- `github`

A separate pool is not created for each repository. Repository-specific isolation is enforced with mapped identity attributes and Secret-level IAM.

## 6. GitHub OIDC Provider

One shared GitHub OIDC Provider is used.

Recommended provider ID:

- `github-actions`

Issuer:

- `https://token.actions.githubusercontent.com/`

The provider accepts OIDC tokens issued to GitHub Actions workflows and maps selected claims into Google Cloud identity attributes.

## 7. Attribute mapping

The initial mapping includes at least:

```text
google.subject                     <- assertion.sub
attribute.repository_id            <- assertion.repository_id
attribute.repository_owner_id      <- assertion.repository_owner_id
attribute.repository               <- assertion.repository
attribute.job_workflow_ref         <- assertion.job_workflow_ref
```

Authorization should prefer the immutable `repository_id` rather than a human-readable repository name.

The `repository` attribute may be used for readability, logging, and operational verification, but it is not the primary authorization key.

## 8. Provider-level condition

The Provider entry condition restricts access to the trusted GitHub owner using `repository_owner_id`.

Conceptually:

```text
assertion.repository_owner_id == "<TRUSTED_GITHUB_OWNER_ID>"
```

This layer admits repositories belonging to the trusted owner without selecting individual repositories. Repository-level isolation is enforced at the Secret IAM layer.

The actual owner ID remains a deployment value and is not fixed in this design document.

## 9. Repository-level Secret isolation

Each caller repository receives a dedicated Secret.

```text
interest-gacha
    -> codex-auth-interest-gacha

project-b
    -> codex-auth-project-b
```

Each repository may read and manage versions only for its own Secret. It must not access another caller repository's Secret.

Secret-level authorization uses the immutable GitHub `repository_id` as its primary repository boundary. Actual repository IDs remain deployment values.

## 10. Secret Manager structure

The design uses one Secret per caller repository.

Examples:

```text
codex-auth-interest-gacha
codex-auth-project-b
codex-auth-project-c
```

The Secret payload is the Codex `auth.json`.

Each Secret contains versions representing authentication state at different points in time:

```text
Secret: codex-auth-interest-gacha

Version 1
Version 2
Version 3
...
```

Only a successfully validated and adopted version is authoritative for the next execution.

## 11. IAM roles

The initial design grants the federated repository principal the following predefined roles on its specific Secret:

- `roles/secretmanager.secretAccessor`
- `roles/secretmanager.secretVersionManager`

These roles are not granted across the entire project. Secret-level bindings provide repository isolation and least privilege.

`Secret Version Manager` includes the ability to destroy versions. To simplify v0.1 implementation, the predefined role is used initially. A later design may separate destroy permission through a custom role or a dedicated cleanup identity.

## 12. Service Account policy

The initial design does not create or impersonate a Service Account.

Used structure:

```text
GitHub Actions
    ↓ OIDC / WIF
Federated principal
    ↓ direct resource access
Secret Manager
```

The following structure is not used initially:

```text
GitHub
    ↓
WIF
    ↓
Service Account
    ↓
Secret Manager
```

Service Account impersonation may be reconsidered only if a future Google Cloud API cannot be used through direct federated resource access or if a later security design requires it.

No long-lived Service Account key is introduced.

## 13. auth.json initial seed

The first Secret version must be seeded manually because no stored authentication state exists initially.

```text
trusted machine
    ↓
codex login
    ↓
auth.json
    ↓
manual secure upload
    ↓
codex-auth-interest-gacha / Version 1
```

The seed is created only in a trusted interactive environment. The `auth.json` file is never committed to this or a caller repository.

After the initial seed, GitHub Actions is expected to manage candidate version creation and adoption automatically.

## 14. Authentication state lifecycle

```text
Version N
authoritative / enabled
    ↓
Codex execution
    ↓
auth.json changed?

NO
    -> create no new version

YES
    -> create Version N+1
    -> treat as candidate
    -> verify storage
    -> verify authentication usability

validation OK
    -> adopt Version N+1
    -> disable Version N

validation NG
    -> keep Version N enabled
    -> do not retire Version N
    -> do not report the job as successful
```

A changed `auth.json` and a valid new authentication state are separate conditions. Change detection alone is not sufficient to adopt a new authoritative state.

## 15. Destruction lifecycle

Secret version destruction is separated from the normal Codex runtime lifecycle.

Runtime lifecycle:

- read the authoritative version
- add a candidate version when authentication state changes
- verify candidate storage and usability
- adopt the candidate
- disable the previous version

Cleanup lifecycle:

- check the retention policy and recovery requirements
- select eligible old disabled versions
- destroy those versions through a controlled cleanup process

The runtime does not immediately destroy the previous version.

## 16. Adding a new caller repository

The conceptual onboarding process is:

1. Determine the immutable GitHub repository ID.
2. Create a repository-specific Secret.
3. Seed the first `auth.json` version from a trusted machine.
4. Add the Secret IAM binding for that repository ID.
5. Add the thin caller workflow to the caller repository.

The shared Workload Identity Pool and Provider are not recreated for each repository.

The resources that normally increase for each caller are:

- one Secret
- one set of Secret IAM bindings

## 17. Authorization layers

The design uses layered authorization:

- Layer 1: Provider-level `repository_owner_id`
- Layer 2: Secret-level `repository_id`
- Layer 3: `job_workflow_ref`-based workflow identity validation

Conceptually:

```text
GitHub OIDC token
    ↓
trusted owner?
    ↓
authorized repository?
    ↓
trusted reusable workflow?
    ↓
Secret access
```

Layers 1 and 2 define the v0.1 base boundary. The concrete enforcement method for Layer 3 remains an open design question.

## 18. Open design question: job_workflow_ref and commit SHA pinning

Caller repositories are expected to pin the reusable workflow to an immutable commit SHA.

GitHub OIDC `job_workflow_ref` includes ref information for the called reusable workflow. Requiring an exact commit SHA in a Google IAM condition may therefore require updating the IAM condition every time the pinned `codex-automation` workflow SHA changes.

It requires separate validation whether trusting only the workflow repository and path is both secure and technically enforceable. Relying only on `repository_id` is operationally simpler, but could allow another workflow in the same caller repository to access the Secret.

The implementation must therefore define workflow identity enforcement before Google Cloud resources or workflows are deployed. This question concerns an additional defense layer and does not invalidate the shared Project, Provider, repository ID, or Secret isolation design.

Candidates to evaluate later:

- A. Require `job_workflow_ref` to match the complete commit SHA.
- B. Fix only the reusable workflow repository and path identity.
- C. Bind Secret IAM to `repository_id` and enforce workflow identity in another layer.
- D. Use another OIDC claim or IAM structure.

No option is selected in v0.1.

## 19. v0.1 decisions

| Topic | v0.1 decision |
|---|---|
| Google Cloud Project | one shared, dedicated project |
| Workload Identity Pool | one shared pool |
| GitHub OIDC Provider | one shared provider |
| Service Account | not used initially |
| Authentication | WIF direct resource access |
| Provider boundary | `repository_owner_id` |
| Repository boundary | `repository_id` |
| Secret | one per caller repository |
| Secret IAM | applied per Secret |
| Authentication state | candidate -> verify -> adopt |
| Previous version | disable after successful adoption |
| Destroy | separate cleanup lifecycle |
| First seed | trusted interactive machine |
| `job_workflow_ref` policy | open design question |
