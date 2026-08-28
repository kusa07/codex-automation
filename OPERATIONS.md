# Operations

## 1. Purpose

This document defines expected runtime behavior, failure handling, and recovery for `codex-automation`.

Detailed commands and runbooks will be added during implementation.

## 2. Normal lifecycle

The intended execution lifecycle is:

```text
Issue receives codex-ready
    ↓
caller workflow starts
    ↓
shared reusable workflow starts
    ↓
repository-level serialization
    ↓
checkout caller repository
    ↓
authenticate to Google Cloud using OIDC / WIF
    ↓
retrieve caller auth.json
    ↓
record auth state
    ↓
prepare Codex CLI
    ↓
validate task
    ↓
run Codex
    ↓
detect auth.json changes
    ↓
store changed auth as a candidate version if necessary
    ↓
validate candidate authentication state
    ↓
adopt only after successful validation
    ↓
retire previous auth version safely
    ↓
publish implementation result
    ↓
create/update Pull Request
    ↓
report result
```

## 3. Serialization

Each caller repository has a serialized Codex execution stream.

If multiple Issues become ready at approximately the same time, they form a repository-level queue and are processed one at a time rather than running concurrently against the same authentication state.

A new run must not simply replace or cancel the Codex job already in progress. The implementation is expected to use GitHub Actions concurrency / queue behavior and to avoid `cancel-in-progress`-equivalent behavior for the Codex execution stream by default. Interrupting a job while it is updating authentication state or a branch may create inconsistent state.

The exact execution order, queue behavior, and YAML syntax will be defined precisely during workflow implementation.

## Repository serialization validation

Repository-level serialization must be validated using two runs from the same
caller repository.

### Procedure

1. Dispatch the caller workflow once.
2. Wait 10 seconds.
3. Dispatch the same caller workflow again.
4. Stop issuing additional runs and observe the two runs.

The two dispatches should normally be performed by the agent rather than
requiring manual human timing.

### Expected intermediate state

While the first run is still executing:

- the first run continues running
- the second run waits in the concurrency queue
- the second run does not execute Codex concurrently with the first run
- the second run does not cancel the first run

### Expected completion state

After the first run completes:

- the first run completes successfully
- the second run leaves the queue and begins execution
- the second run completes successfully
- neither run is cancelled by the newer run

### Validation boundary

This validation proves that runs from the same caller repository are serialized
and that a later run waits instead of cancelling an in-progress run.

Strict FIFO ordering among multiple pending runs is not part of this validation.

Different caller repositories use different repository-scoped concurrency
groups and therefore remain independently serializable.

### Safety

Do not add artificial delay steps to the reusable workflow solely for this
test unless the normal workflow duration is too short to observe queueing
reliably.

Prefer dispatching the normal workflow twice with a short delay between
dispatches.

Do not proceed to the next phase solely because both runs succeeded. Confirm
that the expected serialization behavior was actually observed.

## 4. Successful execution

A successful infrastructure execution means:

- caller identity was validated
- authentication was restored
- Codex completed its requested execution phase
- updated authentication state, if any, was safely persisted
- expected GitHub result was published
- no secret data was exposed

A successful Codex process does not automatically mean that the resulting code should be merged.

## Authentication persistence lifecycle

At preflight, normal operation requires exactly one enabled Secret Manager version. The workflow records its numeric version ID and retrieves that exact version. Zero or multiple enabled versions are an ambiguous recovery state and fail closed; the workflow must not select `latest` or guess which state is authoritative.

The workflow records a non-logged SHA-256 baseline before Codex execution and preserves the Codex process exit code while authentication handling completes.

If `auth.json` is unchanged:

- no new Secret Manager version is created
- no version is disabled or destroyed

If `auth.json` changed:

1. retain the Codex task result for separate final evaluation
2. validate the local candidate with `codex login status`
3. reauthenticate to Google Cloud only for persistence
4. add a candidate Secret Manager version from the file
5. record the numeric candidate version ID
6. read back that exact candidate version
7. verify byte equality with the local candidate
8. install the read-back file and validate it as ChatGPT authentication
9. disable the previous authoritative version only after every validation succeeds
10. verify that the candidate is the only enabled version
11. finally evaluate the retained Codex task result

Candidate payloads, hashes, and authentication status output are not logged. Runtime handling never destroys a Secret version.

## Interrupted authentication adoption

An interruption before the previous version is disabled may leave both the previous version and a candidate enabled. The next run must fail preflight because multiple enabled versions are ambiguous.

Do not automatically repair this state and do not choose the newest or `latest` version. An operator must inspect non-payload version metadata, identify the known-good state through an explicit recovery procedure, and restore the one-enabled-version invariant. Secret payloads and `auth.json` must not be printed during recovery.

## 5. Codex failure

If Codex fails:

- preserve useful sanitized logs
- do not expose credentials
- determine whether `auth.json` changed
- treat any changed `auth.json` as a candidate rather than adopting it unconditionally
- validate a stored candidate before using it as the next authoritative authentication state
- report the failure to the caller
- do not falsely mark the implementation as successful

## 6. Authentication failure

Examples include:

- Codex authentication rejected
- refresh state invalid
- stored auth data unusable

Expected response:

1. stop implementation execution safely
2. report an authentication-class failure
3. do not overwrite a known-good secret with invalid data
4. require trusted re-authentication / reseeding if necessary

Exact reseeding procedures will be documented during implementation.

## 7. Google Cloud authentication failure

If GitHub OIDC / Workload Identity Federation fails:

- Codex must not run without the required credential
- no fallback long-lived service account key should be used
- report an infrastructure authentication failure

## 8. Secret retrieval failure

If the caller's Secret Manager secret cannot be read:

- do not run Codex
- identify the caller repository
- report the failure without printing secret contents
- preserve repository isolation

## 9. Secret persistence failure

If Codex changed `auth.json` but the new version cannot be safely persisted:

- the job must not report full success
- the previous secret version must not be destroyed
- the previous secret version must remain enabled when adoption has not completed
- a created but unadopted candidate should be disabled when possible
- recovery information must be preserved
- further automated execution using uncertain authentication state may need to stop

This is considered a high-priority operational failure.

## 10. New-version verification failure

If a new Secret Manager version was created but cannot be verified as both correctly stored and usable:

- keep the previous version authoritative and enabled
- do not disable or destroy the previous version
- do not adopt the candidate, including when Codex exited abnormally
- treat the authentication update and the job as unsuccessful
- report the failure

## 11. Pull Request failure

If implementation work succeeds but Pull Request creation fails, distinguish this from Codex implementation failure.

Where possible, preserve:

- branch
- commits
- execution result

and report that publication failed.

The implementation should not need to be rerun unnecessarily if the generated work is recoverable.

## 12. Reseeding auth.json

If authentication becomes unrecoverable, a trusted interactive environment may be used to authenticate Codex again and produce a fresh `auth.json`.

That file can then be securely reseeded into the appropriate Secret Manager secret.

The exact trusted-machine and upload procedure will be specified later.

## 13. Observability

The system should make failures classifiable.

Suggested categories:

- CALLER_VALIDATION_FAILED
- OIDC_AUTH_FAILED
- SECRET_READ_FAILED
- CODEX_AUTH_FAILED
- CODEX_EXECUTION_FAILED
- SECRET_WRITE_FAILED
- SECRET_VERIFY_FAILED
- GITHUB_PUBLISH_FAILED
- UNKNOWN_INFRASTRUCTURE_FAILURE

These names are provisional and may change during implementation.

## 14. Operational principle

The system should prefer:

> explicit failure with recoverable state

over:

> apparent success with uncertain authentication or repository state

## 15. Phase 9 Issue task operation

The implemented Phase 9 entry path is:

```text
open Issue receives codex-ready
    ↓
caller issues:labeled workflow
    ↓ issue_number
shared Issue read-back and validation
    ↓ validated runner-local task
Codex read-only analysis
```

Before applying `codex-ready`, confirm that the Issue contains a usable task description and does not require Codex to invent an important product decision. Adding the label authorizes execution; it does not authorize merge or repository writes.

The shared workflow validates the Issue independently of the event payload. It requires a positive Issue number, an existing open Issue rather than a Pull Request, the current `codex-ready` label, and non-empty title and body content. Validation failure is fail-closed: Codex does not run, credentials are not displayed, and the safe task identity may be reported by Issue number.

Phase 9 live validation should confirm:

- a valid `codex-ready` Issue reaches read-only Codex execution
- another label does not invoke the shared job
- a closed, unlabeled, empty, missing, or Pull Request identity does not reach Codex
- logs expose sanitized task identity but do not reproduce the Issue body
- the Phase 8 authentication persistence lifecycle and repository cleanliness checks remain effective

Branch creation, source modification, commits, pushes, and Pull Request publication are Phase 10 behavior and are not part of this operation.

## 16. Phase 10 implementation publication

The Phase 10 normal lifecycle is:

```text
validated Issue
    ↓
resolve trusted default branch
    ↓
verify current remote base commit
    ↓
reject branch or Pull Request collision
    ↓
create deterministic task branch
    ↓
run Codex with workspace-write
    ↓
complete authentication persistence
    ↓
validate repository state and implementation paths
    ↓
stage validated changes
    ↓
create one implementation commit
    ↓
push only the task branch
    ↓
create Draft Pull Request
```

Codex failure, authentication failure, or publication-validation failure
causes commit, push, and Pull Request creation to be skipped.

If push fails, no force push or automatic retry is performed.

If the task branch push succeeds but Draft Pull Request creation fails, the
remote branch and implementation commit are retained. The workflow does not
delete the branch or retry Pull Request creation automatically.

Existing generated branches or Pull Requests are collision states. Phase 10
does not update, overwrite, delete, or suffix them.

Retry, resume, recovery, detailed failure classification, and recovery of a
pushed branch without a Pull Request belong to Phase 11.

### Phase 10 workspace sandbox investigation stop

Phase 10 workspace-write validation is currently blocked in the Linux sandbox
path on the GitHub-hosted Ubuntu 24.04 runner.

Bounded investigation reached its mandatory stop condition.

Observed evidence:

- Run `33145163464` used official `codex-cli 0.148.0` with
  `--sandbox workspace-write`.
- Authentication, WIF, and Secret retrieval succeeded.
- The requested file change did not occur.
- The runtime reported:
  `bwrap: loopback: Failed RTM_NEWADDR`.
- Hiding PATH-based system `bwrap` discovery did not make the file change
  succeed.
- Run `33150524450` attempted a standalone bundled-bwrap control/test probe.
- The bundled resource was resolved successfully, but the probe stopped before
  CONTROL/TEST execution because the fail-closed `bwrap --version` format
  validation rejected the observed output.

Therefore the remaining distinction is unresolved:

- GitHub-hosted Ubuntu / bundled-bwrap namespace compatibility, or
- Codex-specific bwrap invocation / sandbox construction.

The bounded Phase 10 investigation budget is exhausted.

Do not start another sandbox diagnostic experiment automatically.
Further work requires an explicit design decision covering one of:

- Codex CLI version strategy
- runner / environment strategy
- sandbox strategy

Phase 10 remains `Next`.
Phase 11 behavior is not entered by this stop condition.
