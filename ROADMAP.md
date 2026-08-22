# Roadmap

## 1. Purpose

This document is the authoritative roadmap for `codex-automation`.

It defines:

- the official implementation phases
- the current project position
- the purpose of each phase
- the completion criteria for each phase
- the order in which implementation should proceed

The roadmap exists so that the User, ChatGPT, Codex, and future development sessions share the same understanding of project progress.

## 2. Roadmap authority

`ROADMAP.md` is the single source of truth for phase numbering, phase names, phase order, and phase completion state.

The phase structure must not be changed only in conversation, implementation notes, or an individual Codex session.

The following changes require explicit user approval and an update to this file:

- adding a phase
- removing a phase
- renaming a phase
- renumbering a phase
- splitting a phase
- merging phases
- changing phase order
- materially changing completion criteria

If implementation reveals that the roadmap should change, stop and propose the roadmap change before treating the new structure as authoritative.

Before beginning a new phase:

1. Read the latest `ROADMAP.md`.
2. Confirm the current phase and next phase.
3. Confirm that the current phase completion criteria are satisfied.
4. Read the architecture, security, protocol, contract, and operations documents relevant to the next phase.
5. Only then begin implementation.

## 3. Current status

| Phase | Description | Status |
|---|---|---|
| Phase 1 | Core architecture and responsibility boundaries | Complete |
| Phase 2 | Google Cloud / Workload Identity Federation foundation | Complete |
| Phase 3 | Caller-specific Secret Manager and IAM isolation | Complete |
| Phase 4 | Initial `auth.json` seed | Complete |
| Phase 5 | GitHub Actions → WIF → Secret Manager connectivity | Complete |
| Phase 6A | Restore `auth.json` and verify Codex authentication | Complete |
| Phase 6B | Execute a real read-only Codex task | Complete |
| Phase 7 | Repository-level serialization and queueing | Complete |
| Phase 8 | Safe `auth.json` update and persistence lifecycle | Complete |
| Phase 9 | Issue → `codex-ready` → validated Codex task input | Next |
| Phase 10 | Codex implementation → branch / commit / Pull Request | Planned |
| Phase 11 | Failure handling, result reporting, and end-to-end validation | Planned |
| Phase 12 | Multi-repository rollout and operational use | Planned |

Current authoritative position:

> Phase 8 is complete. Phase 9 is the next implementation phase.

## 4. Phase definitions

### Phase 1 — Core architecture and responsibility boundaries

Purpose:

Define the shared architecture and clearly separate responsibilities between application repositories and `codex-automation`.

Key outcomes:

- User / ChatGPT / GitHub / Codex flow defined
- caller repository responsibilities defined
- shared automation responsibilities defined
- GitHub-hosted runner policy defined
- authentication architecture defined
- Issue / PR / Decision operating model defined

Completion criteria:

- architecture documents exist
- caller/shared responsibility boundary is documented
- security principles are documented
- operational direction is documented

Status:

Complete.

---

### Phase 2 — Google Cloud / Workload Identity Federation foundation

Purpose:

Create the Google Cloud trust foundation that allows GitHub Actions to authenticate without long-lived Google service account keys.

Key outcomes:

- dedicated Google Cloud project
- Workload Identity Pool
- GitHub OIDC Provider
- trusted GitHub owner identity
- trusted reusable workflow identity
- immutable workflow SHA authorization model

Completion criteria:

- GitHub OIDC can be accepted by Google Cloud under the intended trust conditions
- provider conditions use the approved identity claims
- no downloaded long-lived service account key is required

Status:

Complete.

---

### Phase 3 — Caller-specific Secret Manager and IAM isolation

Purpose:

Ensure that each caller repository has an isolated Codex authentication boundary.

Key outcomes:

- caller-specific Secret Manager secret
- repository-specific IAM authorization
- immutable repository ID used as the caller authorization boundary
- no project-wide secret access granted to caller repositories

Completion criteria:

- the caller can access only its intended Codex authentication secret
- unrelated repositories cannot use the same authorization boundary
- Secret IAM is isolated from Project IAM

Status:

Complete.

---

### Phase 4 — Initial `auth.json` seed

Purpose:

Establish the first authoritative Codex ChatGPT authentication state in Secret Manager.

Key outcomes:

- trusted local Codex login
- `auth.json` uploaded securely to the caller-specific secret
- uploaded value verified without exposing its contents
- repository contains no authentication material

Completion criteria:

- Secret Manager contains a usable initial `auth.json`
- the stored value matches the trusted seed
- no secret payload is committed or logged

Status:

Complete.

---

### Phase 5 — GitHub Actions → WIF → Secret Manager connectivity

Purpose:

Verify the complete infrastructure path from a caller GitHub Actions workflow to its Secret Manager credential.

Key outcomes:

- thin caller workflow
- reusable shared workflow
- GitHub OIDC authentication
- direct Workload Identity Federation
- Secret Manager retrieval
- temporary runner-local secret handling
- cleanup

Completion criteria:

- caller workflow successfully authenticates to Google Cloud
- intended caller Secret can be retrieved
- credential payload is not printed to logs
- temporary credential material is removed

Status:

Complete.

---

### Phase 6A — Restore `auth.json` and verify Codex authentication

Purpose:

Verify that authentication stored in Secret Manager can be restored into a GitHub-hosted runner and recognized by Codex CLI.

Key outcomes:

- restore `$HOME/.codex/auth.json`
- configure file-based Codex credential storage
- install a pinned Codex CLI version
- confirm ChatGPT authentication
- remove temporary authentication files

Completion criteria:

- `codex login status` recognizes the restored authentication as ChatGPT login
- no authentication payload appears in workflow logs
- runner-local authentication files are cleaned up

Status:

Complete.

---

### Phase 6B — Execute a real read-only Codex task

Purpose:

Prove that Codex can perform a real inference task inside the caller repository using the restored ChatGPT authentication.

Key outcomes:

- execute pinned Codex CLI non-interactively
- use read-only sandbox
- inspect the caller repository
- produce a short repository summary
- verify repository state remains unchanged
- suppress unnecessary Codex execution output
- remove temporary output and credentials

Completion criteria:

- the GitHub Actions run succeeds
- Codex returns a non-empty repository summary
- the caller repository remains clean before and after execution
- no source file is modified
- the workflow SHA migration is finalized to the validated implementation SHA

Status:

Complete.

---

### Phase 7 — Repository-level serialization and queueing

Purpose:

Guarantee that multiple Codex jobs using the same caller authentication state cannot execute concurrently.

This phase protects both repository state and `auth.json` state before authentication persistence or source modification is introduced.

Planned outcomes:

- repository-specific GitHub Actions concurrency group
- one active Codex execution per caller repository
- later runs wait rather than cancel the current execution
- `cancel-in-progress` behavior disabled for the Codex execution stream
- queue behavior verified with multiple test runs

Completion criteria:

- two or more runs started for the same caller cannot execute Codex concurrently
- a newer run does not cancel an already running Codex job
- queued runs begin only after the previous run completes
- different caller repositories remain independently serializable

Status:

Complete.

---

### Phase 8 — Safe `auth.json` update and persistence lifecycle

Purpose:

Safely preserve authentication state when Codex changes `auth.json` during execution.

Planned lifecycle:

1. record the pre-execution authentication state
2. run Codex
3. detect whether `auth.json` changed
4. if unchanged, create no new Secret Manager version
5. if changed, create a candidate Secret Manager version
6. verify the candidate was stored correctly
7. verify the candidate is a usable Codex authentication state
8. adopt the candidate only after successful validation
9. disable the previously authoritative version only after successful adoption
10. retain old versions according to a safe cleanup policy

Important rule:

A changed `auth.json` and a valid replacement authentication state are not the same condition.

A changed file must never be adopted automatically merely because Codex exited successfully.

Completion criteria:

- unchanged authentication creates no unnecessary version
- changed authentication is stored only as a candidate initially
- invalid candidate state cannot replace the known-good state
- previous authoritative state remains recoverable on failure
- secret data is never exposed in logs

Status:

Complete.

---

### Phase 9 — Issue → `codex-ready` → validated Codex task input

Purpose:

Connect GitHub Issues to the shared Codex execution workflow.

Planned outcomes:

- caller workflow reacts to an Issue becoming `codex-ready`
- Issue identity and task context are passed to the reusable workflow
- required task information is validated before Codex execution
- malformed, ambiguous, or unauthorized inputs fail safely
- repository-local instructions remain authoritative for project-specific behavior

Completion criteria:

- a valid `codex-ready` Issue can trigger the shared execution path
- an Issue without execution authorization does not trigger Codex
- task identity is visible in sanitized execution logs
- invalid task input does not reach Codex execution

Status:

Next.

---

### Phase 10 — Codex implementation → branch / commit / Pull Request

Purpose:

Allow Codex to perform real implementation work and publish the result through the normal GitHub review boundary.

Planned outcomes:

- controlled write-capable Codex execution
- task-specific branch creation
- source modifications
- validation / tests
- commits
- Pull Request creation or update
- Issue linkage
- implementation summary

The Pull Request remains the review boundary.

Codex execution does not imply merge authorization.

Completion criteria:

- an authorized Issue can produce an isolated implementation branch
- expected source changes can be committed
- a Pull Request is created or updated
- validation results are reported
- no automatic merge occurs unless explicitly designed and approved later

Status:

Planned.

---

### Phase 11 — Failure handling, result reporting, and end-to-end validation

Purpose:

Turn the working execution path into a recoverable and understandable operational system.

Planned outcomes:

- classified infrastructure failures
- classified Codex failures
- classified authentication failures
- classified Secret persistence failures
- classified GitHub publication failures
- sanitized execution reporting
- recovery procedures
- end-to-end tests across success and representative failure paths

Completion criteria:

- failures can be distinguished by class
- known-good authentication state is preserved during failure
- recoverable GitHub work is not unnecessarily discarded
- operational procedures exist for the expected failure modes
- a complete Issue → Codex → PR test succeeds

Status:

Planned.

---

### Phase 12 — Multi-repository rollout and operational use

Purpose:

Confirm that `codex-automation` works as a reusable shared platform rather than as a single-project integration.

Planned outcomes:

- onboard at least one additional caller repository
- caller-specific Secret and IAM boundary creation
- thin caller workflow reuse
- independent repository queueing
- independent authentication state
- common operational process
- documentation updated to reflect real operation

Completion criteria:

- more than one caller repository can use the shared infrastructure
- each caller remains isolated
- reusable workflow changes can be deliberately rolled out through immutable SHA updates
- routine operation no longer requires architecture redesign

Status:

Planned.

## 5. Related documents

`ROADMAP.md` answers:

> What is being built, where are we now, and what comes next?

Other documents answer different questions:

- `README.md`
  - What is this repository?

- `ARCHITECTURE.md`
  - How is the system structured?

- `GOOGLE_CLOUD.md`
  - How is Google Cloud / WIF / Secret Manager designed?

- `CONTRACT.md`
  - What is the interface between callers and the shared automation layer?

- `PROTOCOL.md`
  - How does work move from User → ChatGPT → Issue → Codex → PR?

- `SECURITY.md`
  - What security rules must always hold?

- `OPERATIONS.md`
  - How should execution, failure handling, and recovery behave?

- `AGENTS.md`
  - What must Codex read and respect before modifying this repository?

## 6. Roadmap maintenance principle

The roadmap should describe meaningful implementation milestones, not every individual commit.

Small implementation steps, tests, fixes, and SHA migrations may happen inside a phase without creating new phase numbers.

If a phase becomes too large or its intended boundary is no longer appropriate, propose a roadmap revision explicitly rather than silently inventing a new phase.
