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

For Phase 10 Self-hosted Execution, the approved operational path inserts a persistent-host preflight and local serialization boundary before local Codex execution:

```text
validated Issue
    ↓
runner availability pre-check
    ↓
self-hosted job dispatch
    ↓
managed execution-area validation
    ↓
schema validation
    ↓
local execution lock
    ↓
residual-state preflight
    ↓
execution ID / current-run state
    ↓
workspace preparation
    ↓
OIDC / WIF / Secret restore
    ↓
isolated Local Codex runtime
    ↓
Local Codex execution
    ↓
authentication persistence lifecycle
    ↓
trusted publication
    ↓
cleanup
    ↓
post-run residual-state validation
    ↓
execution state completion
    ↓
local lock release
```

The detailed Self-hosted Execution architecture is defined in `SELF_HOSTED_EXECUTION.md`.

## 3. Serialization

Each caller repository has a serialized Codex execution stream.

If multiple Issues become ready at approximately the same time, they form a repository-level queue and are processed one at a time rather than running concurrently against the same authentication state.

A new run must not simply replace or cancel the Codex job already in progress. The implementation is expected to use GitHub Actions concurrency / queue behavior and to avoid `cancel-in-progress`-equivalent behavior for the Codex execution stream by default. Interrupting a job while it is updating authentication state or a branch may create inconsistent state.

Self-hosted execution adds a second serialization layer. The initial Phase 10 design allows only one active job in a Self-hosted Execution Area at a time.

Therefore:

```text
GitHub Actions concurrency
    = caller / auth-stream serialization

local execution lock
    = persistent execution-area serialization
```

Both controls are required. Neither replaces the other.

The initial local lock implementation should use a Windows named Mutex. If the Mutex is detected as abandoned, the execution must treat that as evidence of a possibly interrupted prior run rather than as a normal release. The job must continue into residual-state inspection and fail closed if the state is ambiguous or unsafe.

A lock-file implementation should not be substituted without an explicit staleness-detection design.

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
groups and therefore remain independently serializable at the GitHub Actions layer.

The Self-hosted Execution Area remains globally serialized to one local job at a time in the initial design even when different caller repositories are independently queueable in GitHub Actions.

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
- the approved execution environment passed preflight
- authentication was restored
- Codex completed its requested execution phase
- updated authentication state, if any, was safely persisted
- expected GitHub result was published
- required cleanup and residual-state validation succeeded
- no secret data was exposed

A successful Codex process does not automatically mean that the resulting code should be merged.

For Self-hosted Execution, a successful Codex process is not sufficient to report full success if required security cleanup or final residual-state validation fails.

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
- complete required Self-hosted cleanup where practical
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

## 13. Observability and audit events

The system should make failures classifiable.

Suggested categories:

- CALLER_VALIDATION_FAILED
- RUNNER_OFFLINE
- RUNNER_BUSY
- RUNNER_INELIGIBLE
- SELF_HOSTED_PREFLIGHT_FAILED
- SELF_HOSTED_LOCK_ABANDONED
- SELF_HOSTED_STATE_INVALID
- SELF_HOSTED_CLEANUP_FAILED
- OIDC_AUTH_FAILED
- SECRET_READ_FAILED
- CODEX_AUTH_FAILED
- CODEX_EXECUTION_FAILED
- SECRET_WRITE_FAILED
- SECRET_VERIFY_FAILED
- GITHUB_PUBLISH_FAILED
- UNKNOWN_INFRASTRUCTURE_FAILURE

These names remain provisional until Phase 11 formalizes the result contract.

For Self-hosted Execution, security-relevant lifecycle events should be emitted in sanitized form to GitHub Actions logs. Initial event names may include:

- `EXECUTION_STARTED`
- `PREFLIGHT_PASSED`
- `CREDENTIAL_RESTORED`
- `CODEX_STARTED`
- `CODEX_FINISHED`
- `CREDENTIAL_REMOVED`
- `CLEANUP_PASSED`
- `ABANDONED_LOCK_DETECTED`
- `FAIL_CLOSED`

Local execution-area logs are supplementary diagnostics. They are not the only audit trail for security-relevant lifecycle events.

Audit output must not include credential payloads, tokens, secret contents, or sensitive comparison hashes.

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

The approved Phase 10 Self-hosted lifecycle is:

```text
validated Issue
    ↓
runner availability pre-check
    ↓
self-hosted dispatch
    ↓
managed-area / schema preflight
    ↓
local execution lock
    ↓
execution state / workspace preparation
    ↓
resolve trusted default branch
    ↓
verify current remote base commit
    ↓
reject branch or Pull Request collision
    ↓
create deterministic task branch
    ↓
run Local Codex with controlled working-tree write access
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
    ↓
cleanup / residual-state validation
```

Codex failure, authentication failure, Self-hosted preflight failure, cleanup failure, or publication-validation failure prevents a full-success result. Commit, push, and Pull Request creation must be skipped whenever their prerequisites are not satisfied.

If push fails, no force push or automatic retry is performed.

If the task branch push succeeds but Draft Pull Request creation fails, the remote branch and implementation commit are retained. The workflow does not delete the branch or retry Pull Request creation automatically.

Existing generated branches or Pull Requests are collision states. Phase 10 does not update, overwrite, delete, or suffix them.

Retry, resume, recovery, detailed failure classification, and recovery of a pushed branch without a Pull Request belong to Phase 11 unless explicitly brought into Phase 10 by approved design change.

### Self-hosted execution identity and atomic state

Each Self-hosted run must have an execution identity that is unique to the GitHub execution context. The initial design may derive it from values such as:

```text
repository_id + github_run_id + github_run_attempt
```

The execution ID is used to detect duplicate or conflicting local execution state.

The managed-area identity marker and mutable execution-state files such as `current-run.json` must be written atomically. The implementation should use a write-to-temporary-file, flush/close, then atomic rename/replace pattern.

Unreadable state, parse failure, missing required fields, unsupported schema, or internally inconsistent state must fail closed rather than be guessed or silently repaired.

### Interrupted Self-hosted execution

The initial Phase 10 design does not automatically resume or automatically rerun an interrupted Local Codex execution.

Possible interruption causes include:

- host shutdown or restart
- runner service termination
- process crash
- power loss
- network loss
- workflow cancellation

Post-job cleanup may not run in these cases. The next job must therefore perform preflight and inspect the managed locations and execution state before restoring credentials or starting Codex.

Security-relevant residue or ambiguous state must fail closed and require explicit recovery. Normal execution must not perform destructive automatic recovery.

### Credential-location policy

Self-hosted credential handling is verified against known automation-managed locations rather than attempting to scan the entire host for possible copies.

The implementation must restrict where it writes:

- Codex authentication files
- Google credential files
- temporary GitHub credential helpers
- other sensitive per-run material

Cleanup removes these known temporary files and verifies that the expected managed locations no longer contain active credential material.

The design does not claim forensic secure deletion from SSD or other storage media.

### Execution-area schema migration

Normal execution must not automatically migrate an older or unsupported Self-hosted Execution Area schema.

Conceptually:

```text
expected schema == local schema
    -> continue

expected schema != local schema
    -> STOP
       require explicit setup / migration action
```

Unknown or malformed managed-area state must not be converted automatically during a normal task run.

### Phase 10 Self-hosted validation sequence

The Self-hosted Execution path should be validated incrementally:

1. approve Self-hosted Execution architecture
2. create and validate the managed execution area
3. validate ensure / preflight behavior
4. register and validate the self-hosted runner
5. run an inert job without Codex credentials
6. validate workspace creation and cleanup
7. validate WIF / Secret Manager access from the self-hosted path
8. validate isolated Codex authentication restore and cleanup
9. run one Codex read-only task
10. run one minimal controlled workspace-write task
11. reconnect the existing trusted publication path
12. validate Issue → Codex → Draft Pull Request end to end

Phase 10 remains `Next` until the existing `ROADMAP.md` completion criteria are satisfied.

### Phase 10 workspace sandbox investigation stop

Phase 10 workspace-write validation was blocked in the Linux sandbox path on the GitHub-hosted Ubuntu 24.04 runner.

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

Therefore the remaining distinction was unresolved:

- GitHub-hosted Ubuntu / bundled-bwrap namespace compatibility, or
- Codex-specific bwrap invocation / sandbox construction.

The bounded GitHub-hosted Phase 10 investigation budget is exhausted and remains closed.

The explicit runner strategy decision has now been made: Phase 10 proceeds through the approved Self-hosted Execution architecture defined in `SELF_HOSTED_EXECUTION.md`.

Do not resume the GitHub-hosted workspace-write / bwrap investigation automatically. Reopening that investigation requires explicit user direction.

Phase 10 remains `Next`.
Phase 11 behavior is not entered merely by adopting the Self-hosted strategy.

## 17. Phase 11 sanitized execution result contract

Phase 11 reports a single, fixed-field result record for the execution
boundary. It is an operational summary, not a copy of stderr or task input.
Every record contains:

- `RESULT_CLASS`: `INFRASTRUCTURE_RUNNER`, `CODEX_MODEL`,
  `AUTHENTICATION_SECRET`, `WORKSPACE_GITHUB_PUBLICATION`, `UNKNOWN`, or
  `SUCCESS`
- `RESULT_CODE`: the detailed fixed code that produced the grouping
- `RESULT_CAUSE`: a fixed, sanitized explanation
- `RESULT_PRESERVED_STATE`: the state deliberately retained rather than
  overwritten or discarded
- `RESULT_SAFE_ACTION`: exactly one of `RETRY`, `RECOVER_THEN_RETRY`,
  `USER_DECISION`, or, for successful validation, `USER_REVIEW`

`scripts/self-hosted/execution-result.sh` is the source of truth for this
mapping. It accepts only a fixed detailed code and deliberately cannot accept
raw exception text, task content, repository content, or credential material.

The detailed codes retain useful distinctions within the broad groups. For
example, runner availability and execution-area cleanup are both
`INFRASTRUCTURE_RUNNER`, while `CODEX_AUTH_FAILED` and
`SECRET_VERIFY_FAILED` are both `AUTHENTICATION_SECRET`. A cleanup or residual
state failure requires `RECOVER_THEN_RETRY`; an unaccepted Codex credential or
an unknown condition requires `USER_DECISION`. A failed trusted publication
retains an already-created branch and commit for verified recovery instead of
rerunning implementation needlessly.

This result contract does not automate recovery, expose sensitive detail, or
broaden any credential, runner, GitHub, WIF, or publication authority. An
unsupported code is rejected rather than guessed.

## 18. Phase 10 execution planning and grounding

The detailed Phase 10 implementation work units, read-only grounding gate, STOP conditions, task-result contract, and handoff rules are defined in `PHASE10_EXECUTION_PLAN.md`.

The operational validation sequence in this document remains the lifecycle-level reference. `PHASE10_EXECUTION_PLAN.md` groups those logical steps into the approved `CA-P10-028` through `CA-P10-033` Codex instruction units.

Before a Phase 10 task performs writes, the Parent agent must ground the prompt against the actual repository, documentation, local environment, and previous-task result, then classify the task as `PROCEED`, `ADJUST_WITHIN_SCOPE`, or `STOP_AND_REPORT` according to the plan.

A planned implementation detail must not override actual safe state. If grounding reveals a material architecture, security, roadmap, caller-contract, or runtime-strategy mismatch, stop and report rather than broadening the investigation or silently redesigning the system.

The next task must be prepared from the execution plan plus the actual result of the previous task. Do not advance merely because the previous task was expected to succeed.
