# Phase 12B implementation design

This is the implementation companion to the approved architecture reference
`d6b56ec250615c7d4c0b3ab5f476632c7c14240f`
(`docs/phase12b-onboarding-host-recovery-design`). It specifies the public
Batch A contracts that later Batch B/C/D operations execute. It does not itself
authorize a production caller, WIF, host, runner, or Secret mutation.

## Boundaries and identities

The Bootstrap Operator, runner Windows service identity, runner registration,
and caller-scoped Codex authentication are separate identities. The standard
runner service identity is `NT AUTHORITY\NETWORK SERVICE` (`S-1-5-20`).
Personal SIDs and an interactive user profile are not part of the shared
implementation. The automation profile is configured under
`C:\ProgramData\CodexAutomation\profile`; its values are desired state, not
implicit user state.

Each active caller has one repository-scoped runner. The host, Windows service
identity, execution area, and Global Mutex remain shared host resources; this
is not an OS-level caller isolation guarantee. Caller isolation remains
enforced by repository ID, Secret/IAM resource boundary, runner registration,
workspace, temporary runtime, and trusted publication guards.

## Desired-state inputs

Private desired state contains `environment.yaml`, `hosts/<host>.yaml`, and
active or retired caller records. YAML parsing requires mikefarah `yq` v4; a
missing, unsupported, malformed, incomplete, or unknown critical state stops
with exit code 2. There is no shell YAML parser or fallback.

Environment state holds the GitHub owner ID, automation repository/workflow,
the active immutable workflow SHA, and exact Google Provider resource. The
active SHA is the caller rollout target, not the complete WIF allow-list.
Caller repository ID is primary identity. `secret.id` is literal desired state
and is never derived or renamed from a repository name. Host configuration
requires execution, runner, runtime, and profile roots, NETWORK SERVICE,
approved labels, and global-mutex serialization.

## State classifications and STOP rules

Host and repository runner state are `NEW`, `EXISTING`, or `INCONSISTENT`.
Only a wholly absent host is NEW. Existing means valid managed marker/schema,
matching host identity, non-reparse roots, clean execution area, exact service
identity, exact ACL policy, and complete runner/service/GitHub registration.
Partial directories, marker/schema errors, residue, ACL drift, wrong labels,
or any partial runner registration are INCONSISTENT and stop.

Caller state is `NEW`, `ACTIVE_MATCH`, `RETIRED_MATCH`, or
`IDENTITY_CONFLICT`. Duplicate active/retired records, matching names with
different IDs, or competing records stop. Re-onboarding may form a restore
candidate only for an explicit existing numeric disabled Secret version whose
repository ID, Secret ID, authentication validity, and zero-enabled-version
state all exactly match. `latest`, a highest version, or disabled-version
guessing is prohibited.

Caller workflow state is `ABSENT`, `EXACT_TARGET`, `MANAGED_OLD`, or
`DIVERGED`. A known old canonical template may be fully replaced with the
target template after approval and exact remote read-back. Diverged content is
never overwritten. ABSENT stays an onboarding candidate, not an automatic
sync action.

## Common command contract

Operator commands first perform read-only grounding, emit a consolidated plan,
and require one explicit approval for apply. `RESULT=PASS` returns exit 0,
operational failure returns 1, and a safety/ambiguous STOP returns 2. Audit
entries use sanitized JSONL only: timestamp, operation, host/repository IDs,
state, resource names, runner name, workflow SHA, and Secret version ID are
allowed; payloads, tokens, credentials, registration tokens, hashes, and
Secret values are prohibited.

`onboard-caller.sh` grounds operator auth, environment/caller desired state,
GitHub repository ID, caller lifecycle, Secret/IAM metadata, current caller
workflow, runner and service state. Its approved apply path calls the existing
Google Cloud caller helper, installs the canonical caller workflow, provisions
the repository runner/service, read-backs each resource, verifies the host,
and audits. It is exercised only through fixtures/mocks in Batch A.

`offboard-caller.sh` captures authoritative non-payload Secret metadata before
its plan. Approved apply quiesces the caller, stops/unregisters its runner,
disables/removes its workflow, revokes Secret IAM, disables the explicit
authoritative version, checks zero enabled versions, read-backs, moves desired
state active-to-retired, and audits. It never destroys the Secret resource.

`sync-caller-workflow.sh --repository <owner/repo> --private-config <path>
--target-workflow-sha <sha>` grounds repository ID, caller desired state,
literal Secret ID, remote current workflow, known canonical old templates, and
the rendered target. Only `MANAGED_OLD` may apply a complete target workflow;
the post-write GitHub read-back must be byte-identical.

## Host scripts

`bootstrap-host.ps1` parses private configuration and reports runtime/profile,
execution area, ACL, runner root, caller runners, and service actions. Approved
apply is limited to a proven NEW host; it creates and verifies runtime/profile
and managed execution area, applies exact ACLs, and creates configured
repository runners/services through the canonical caller lifecycle and fixed
official GitHub runner provider.

`verify-host.ps1` is read-only. It reports CONFIG, HOST_RUNTIME,
EXECUTION_AREA, MARKER, SCHEMA, SERVICE_IDENTITY, PROFILE, ACL, MUTEX_POLICY,
WIF, CALLER_CONFIG, REPOSITORY_ID, Secret metadata, IAM, RUNNER,
WINDOWS_SERVICE, and CALLER_WORKFLOW without reading a Secret payload.
Each managed root must have inheritance disabled and exactly the three approved
explicit FullControl ACEs; inherited or additional access fails verification.

`migrate-host.ps1` is separate from bootstrap. It grounds current and target
state, emits a migration plan, requires approval, verifies quiescence (no
active/queued workflow, local run, held Global Mutex, or residual state), then
routes migration through the canonical caller lifecycle and full verification.
No normal run
silently changes identity, ACL, root, marker/schema, or runner architecture.

Migration does not broaden `HOST_STATE`. It separately reports
`MIGRATION_SOURCE_STATE` as `CURRENT_MANAGED`,
`LEGACY_PHASE10_INTERACTIVE`, `UNSUPPORTED_PARTIAL`, or `CONFLICT`. Only the
complete Phase 10 fingerprint is automatically migratable: managed execution
area inspect and clean preflight, no execution ownership/residue/process,
the deterministic private `migrations/<host_id>.yaml` source directory and
caller reference, local `.runner` metadata matching exactly one idle GitHub
repository runner with canonical labels, no legacy Service, absent target
roots, and a trusted non-divergent caller workflow. The caller desired state,
GitHub repository ID, local runner ID/name/repository URL, and GitHub runner
registration must agree exactly. Partial or ambiguous evidence stops.

Before target mutation, migration atomically publishes
`runtime_root\migration\host-migration.json`. Durable lifecycle stages are
reconciled with filesystem, Service, and GitHub read-back on resume. A
reversible workflow dispatch fence is read back before quiescence; Batch C
does not change workflow content or its immutable pin. The execution area and
its actual `execution_area_id` are frozen into the migration intent and
preserved, while the configured source runner directory and `_work` remain
retained as non-authoritative evidence.

Runner registration read-back is complete only after every GitHub API page is
validated against one stable `total_count`, with duplicate IDs and truncation
rejected. Final dispatch restoration is itself durable through
`DISPATCH_RESTORING` and `DISPATCH_RESTORED`, including the older
`ACTIVE_VERIFIED`/already-restored crash window.

The private migration desired state pins an exact semantic runner version and
lowercase SHA-256. Public code deterministically constructs the official
`actions/runner` release asset name and URL, requires the GitHub release asset
digest to match the configured SHA-256, and verifies the downloaded file hash
before extraction. Arbitrary URLs, latest-version lookup, and fallback package
authority are not permitted.
Extraction uses intent `operation_id` staging beneath the canonical runner root.
Only a complete, non-reparse package tree is atomically renamed to the final
repository runner directory. Current-operation partial staging may be rebuilt;
unknown staging and partial final roots require operator review.

Explicit TestMode replaces only external state and mutation providers. Caller
lifecycle scripts still invoke `caller-runner.ps1` and the same classification,
recovery, quiescence, and lifecycle transition logic used by production.

Completed Offboard reruns resolve the retired desired-state authority only as
the deterministic sibling of `callers/<name>.yaml` at
`retired-callers/<name>.yaml`; no independent retired-path authority is
accepted. When the active entry is absent, the retired record, local `RETIRED`
metadata, immutable repository ID, exact Secret/version state, IAM absence,
workflow retirement, and runner/service absence must all agree. The rerun then
performs read-only final verification and reports `RETIRED_VERIFIED` with no
mutation. TestMode removes the active entry at the same lifecycle boundary and
uses this same caller-resolution and state-machine path.

## Rollout order

1. Merge Batch A source and record its immutable SHA.
2. Stage that SHA with existing `rotate-workflow-sha.sh`.
3. Create private desired state in Batch B.
4. Run Batch C host migration under quiescence and verify it.
5. Run Batch C.1 caller workflow synchronization.
6. Perform Batch D bounded caller E2E validation.
7. Only after success, explicitly finalize the superseded SHA.

Batch A does not stage/finalize WIF, alter a caller pin, migrate a real host,
register a real runner, change a Secret version, or onboard/offboard a caller.
