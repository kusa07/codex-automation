# Google Cloud Architecture

## 1. Purpose

This document defines the v0.2 Google Cloud design for authentication, Secret Manager lifecycle, and IAM isolation used by `codex-automation`.

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
- reusable workflow identity and approved implementation version validation

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
GitHub caller repository
    ↓ reusable workflow
kusa07/codex-automation/.github/workflows/codex-run.yml
    ↓ GitHub OIDC
Workload Identity Provider
    ↓ owner + workflow path + approved workflow SHA validation
Federated principal
    ↓ repository ID + Secret-level IAM
caller-specific Secret
```

## 4. Google Cloud Project

The design uses one Google Cloud Project dedicated to the Codex authentication infrastructure.

The conceptual project name is `codex-automation`. Because a Google Cloud Project ID must be globally unique, implementation selects an available unique ID rather than assuming this conceptual name is available.

Application workloads and application-specific infrastructure are not placed in this project. Project creation and billing configuration remain manual prerequisites and are not performed by the Phase 1 scripts.

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

The Provider accepts OIDC tokens issued to GitHub Actions workflows and maps selected claims into Google Cloud identity attributes.

## 7. Attribute mapping

The Provider maps at least:

```text
google.subject                     <- assertion.sub
attribute.repository_id            <- assertion.repository_id
attribute.repository_owner_id      <- assertion.repository_owner_id
attribute.repository               <- assertion.repository
attribute.job_workflow_ref         <- assertion.job_workflow_ref
attribute.job_workflow_sha         <- assertion.job_workflow_sha
```

Authorization prefers immutable IDs and implementation hashes. The human-readable `repository` attribute may be used for logging and operational verification, but it is not an authorization primary key.

## 8. Provider-level condition

The Provider accepts a token only when all of the following are true:

1. `repository_owner_id` matches the trusted GitHub owner.
2. `job_workflow_ref` identifies `kusa07/codex-automation/.github/workflows/codex-run.yml`.
3. `job_workflow_sha` is in the explicitly approved workflow SHA list.

Conceptually:

```text
assertion.repository_owner_id == "<TRUSTED_GITHUB_OWNER_ID>"
AND assertion.job_workflow_ref starts with
    "kusa07/codex-automation/.github/workflows/codex-run.yml@"
AND assertion.job_workflow_sha is one of <APPROVED_WORKFLOW_SHAS>
```

The workflow ref check fixes the reusable workflow repository and path while allowing callers to pin an immutable ref. The separate SHA check identifies the approved implementation version.

The Phase 1 scripts accept owner ID, workflow identity, and approved SHA values as runtime inputs. When no SHA has been approved during bootstrap, the generated condition uses a non-matching sentinel and therefore does not admit a GitHub token.

## 9. Repository-level Secret isolation

Each caller repository receives a dedicated Secret.

```text
interest-gacha
    -> codex-auth-interest-gacha

project-b
    -> codex-auth-project-b
```

Each repository may read and manage versions only for its own Secret. It must not access another caller repository's Secret.

Secret IAM binds the immutable GitHub `repository_id` by using a federated principal set containing the Google Cloud Project Number:

```text
principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/attribute.repository_id/<REPOSITORY_ID>
```

## 10. Secret Manager structure

The design uses one Secret per caller repository.

Examples:

```text
codex-auth-interest-gacha
codex-auth-project-b
codex-auth-project-c
```

The Secret payload is the Codex `auth.json`. Phase 1 does not read, write, display, or provide an example payload.

Each Secret contains versions representing authentication state at different points in time. Only a successfully validated and adopted version is authoritative for the next execution.

## 11. IAM roles

The initial design grants the federated repository principal the following predefined roles on its specific Secret:

- `roles/secretmanager.secretAccessor`
- `roles/secretmanager.secretVersionManager`

These roles are not granted across the entire project. Secret-level bindings provide repository isolation and least privilege.

`Secret Version Manager` includes the ability to destroy versions. To simplify the initial implementation, the predefined role is used. A later design may separate destroy permission through a custom role or a dedicated cleanup identity.

## 12. Service Account policy

The initial design does not create or impersonate a Service Account.

```text
GitHub Actions
    ↓ OIDC / WIF
Federated principal
    ↓ direct resource access
Secret Manager
```

Service Account impersonation may be reconsidered only if a future Google Cloud API cannot be used through direct federated resource access or if a later security design requires it. No long-lived Service Account key is introduced.

## 13. auth.json initial seed

The first Secret version must be seeded manually because no stored authentication state exists initially.

```text
trusted machine
    ↓ codex login
auth.json
    ↓ manual secure upload
caller-specific Secret / Version 1
```

The seed is created only in a trusted interactive environment. The file is never committed to this or a caller repository. Phase 1 does not implement or automate seeding.

## 14. Authentication state lifecycle

```text
Version N (authoritative / enabled)
    ↓ Codex execution
auth.json changed?

NO
    -> create no new version

YES
    -> create Version N+1 as candidate
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

A changed `auth.json` and a valid new authentication state are separate conditions. Phase 1 does not implement this lifecycle.

## 15. Destruction lifecycle

Secret version destruction remains separate from the normal Codex runtime lifecycle.

Runtime lifecycle:

- read
- add a candidate version
- verify
- adopt
- disable the previous version

Cleanup lifecycle:

- check retention and recovery requirements
- destroy eligible old disabled versions through a controlled process

The Phase 1 scripts do not destroy Secret versions or other resources.

## 16. Adding a new caller repository

The conceptual onboarding process is:

1. Determine the immutable GitHub repository ID.
2. Create a repository-specific Secret.
3. Add Secret IAM bindings for that repository ID.
4. Seed the first `auth.json` version manually from a trusted machine.
5. Add the thin caller workflow in a later phase.

The shared Workload Identity Pool and Provider are not recreated for each repository. The resources normally added for each caller are one Secret and its Secret IAM bindings.

## 17. Authorization layers

The v0.2 design uses four checks:

| Layer | Location | Claim | Purpose |
|---|---|---|---|
| 1 | WIF Provider | `repository_owner_id` | trusted GitHub owner |
| 2 | WIF Provider | `job_workflow_ref` | trusted reusable workflow repository and path |
| 3 | WIF Provider | `job_workflow_sha` | explicitly approved workflow implementation version |
| 4 | Secret IAM | `repository_id` | caller authorization for one Secret |

```text
GitHub OIDC token
    ↓ trusted owner?
    ↓ trusted reusable workflow path?
    ↓ approved reusable workflow SHA?
Federated principal
    ↓ authorized caller repository ID?
Secret access
```

The Provider boundary controls entry to the shared federation trust. Secret IAM preserves caller-to-Secret isolation.

## 18. Resolved design: job_workflow_ref and job_workflow_sha

The v0.1 open design question is resolved as follows:

- `job_workflow_ref` identifies the trusted reusable workflow repository and fixed path.
- `job_workflow_sha` identifies an explicitly approved immutable implementation version.
- `repository_id` alone is not sufficient because another workflow in the same caller repository could otherwise request the same Secret access.
- Exact version approval is maintained in the WIF Provider condition, not in each Secret IAM policy.

Caller repositories still pin the reusable workflow to an immutable commit SHA. Google Cloud separately verifies that the resolved called workflow SHA is approved.

### Workflow SHA rotation

For a transition from SHA-A to SHA-B:

1. Create and review workflow version SHA-B.
2. Stage the Provider condition so that SHA-A and SHA-B are both approved.
3. Update caller repositories to pin SHA-B.
4. Verify OIDC and Secret access through SHA-B.
5. Explicitly finalize the Provider condition by removing SHA-A.

The old SHA is never removed before caller migration. `rotate-workflow-sha.sh` does not remove it automatically; finalization requires a separate mode and explicit confirmation.

## 19. v0.2 decisions

| Topic | v0.2 decision |
|---|---|
| Google Cloud Project | one shared, dedicated existing project |
| Workload Identity Pool | one shared pool |
| GitHub OIDC Provider | one shared provider |
| Service Account | not used initially |
| Authentication | WIF direct resource access |
| Provider owner boundary | `repository_owner_id` |
| Provider workflow identity | `job_workflow_ref` repository and fixed path |
| Provider workflow version | approved `job_workflow_sha` list |
| Repository boundary | Secret IAM with `repository_id` |
| Secret | one per caller repository |
| Secret IAM | applied per Secret |
| Workflow rotation | temporarily approve old and new SHA |
| Authentication state | candidate -> verify -> adopt |
| Previous version | disable after successful adoption |
| Destroy | separate cleanup lifecycle |
| First seed | trusted interactive machine |

## 20. Phase 1 files and intended execution order

Phase 1 adds:

- `.github/workflows/codex-run.yml`: reusable Workflow skeleton with OIDC permission, but no Google authentication or Codex execution.
- `scripts/google-cloud/bootstrap.sh`: enables required APIs and creates or updates the shared Pool and Provider.
- `scripts/google-cloud/add-caller.sh`: creates a caller Secret when absent and adds repository-ID-specific Secret IAM bindings.
- `scripts/google-cloud/rotate-workflow-sha.sh`: initializes, stages, or explicitly finalizes the approved workflow SHA condition.

The scripts are preparation artifacts and are not executed as part of Phase 1.

Intended later sequence:

1. A human creates the Google Cloud Project and configures billing.
2. Review the scripts and the committed reusable Workflow.
3. Record the Workflow commit SHA.
4. Run `bootstrap.sh` with that SHA, or bootstrap with no approved SHA and then use `rotate-workflow-sha.sh initialize`.
5. Use `add-caller.sh` to create caller-specific Secret metadata and IAM.
6. A human securely seeds the first `auth.json` version from a trusted machine.
7. Implement the caller Workflow in the next phase.
8. Test OIDC and Secret access before implementing Codex execution.


