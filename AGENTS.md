# AGENTS.md

## Purpose

This file defines repository-level instructions for Codex and other implementation agents working on `codex-automation`.

These instructions apply to the entire repository.

## Before starting work

Before modifying this repository:

1. Read `ROADMAP.md`.
2. Identify the authoritative current phase.
3. Identify whether the requested work belongs to that phase.
4. Read the design documents relevant to the requested change.
5. Confirm that the requested work does not violate the security or caller-contract boundaries.

Do not rely on remembered phase numbering from a previous session.

Always use the current repository version of `ROADMAP.md` as the source of truth.

## Roadmap rules

`ROADMAP.md` is authoritative for:

- phase numbering
- phase names
- phase order
- current phase
- phase completion state
- completion criteria

Do not independently:

- add a phase
- remove a phase
- rename a phase
- renumber a phase
- split a phase
- merge phases
- reorder phases
- mark a phase complete
- begin a later phase when the current phase completion criteria are not satisfied

If implementation reveals that a roadmap change would be useful or necessary:

1. stop before treating the new structure as authoritative
2. explain the reason
3. propose the roadmap change
4. wait for explicit user approval

Small implementation steps inside a phase do not require new phase numbers.

## Automation-first operation

Prefer agent-executed or automated operations over manual human steps when
the operation can be performed safely and verified afterward.

Examples include:

- command execution
- repository state checks
- commit and SHA verification
- approved workflow SHA migration steps
- workflow dispatch
- timed or repeated workflow dispatch for validation
- result collection
- post-operation read-back verification

Human involvement should primarily remain at explicit approval and decision
boundaries, especially for:

- design decisions
- approval of proposed file changes before modification
- destructive or difficult-to-reverse operations
- security boundary changes
- unexpected states that require judgment
- phase transitions

Do not automate an operation merely to remove a human step if doing so weakens
an existing safety boundary, approval requirement, or verification requirement.

Automation does not replace explicit user approval where this repository or the
current instructions require that approval.

## Scope discipline

Implement only the requested scope.

Do not proceed automatically into the next roadmap phase after completing the requested task.

If the requested task is a bounded migration, test, validation, or cleanup step, stop after that step and report the result.

Do not perform unrelated refactoring or documentation changes unless they are required for correctness or explicitly requested.

## Investigation expansion guardrail

When debugging or root-cause investigation begins to expand beyond the planned
implementation work, use a bounded investigation cycle by default:

1. perform one read-only cause-classification step
2. perform one targeted experiment based on that classification
3. if necessary, perform at most one additional targeted experiment
4. if the problem is still unresolved, stop before continuing the investigation

At that stop point, do not automatically add more diagnostic tasks, broaden the
investigation, redesign the architecture, replace major tooling, change the
runtime strategy, or continue creating additional experiment IDs.

Instead, report the situation to the user and explicitly include:

- what is currently known
- what has been ruled out
- what the bounded experiments showed
- what remains uncertain
- the likely next options and their tradeoffs
- how much further work each option may add to the current phase

Then wait for explicit user direction before proceeding.

For the current Phase 10 workspace-sandbox investigation, the binding sequence
is: cause classification, one targeted experiment, at most one additional
targeted experiment, then a mandatory user checkpoint if the issue remains
unresolved.

A different investigation limit may be used only when the user explicitly
approves it for the task.

## Required design context

Use the following documents according to the task:

- `ROADMAP.md`
  - project phase and current position

- `ARCHITECTURE.md`
  - component responsibilities and system structure

- `GOOGLE_CLOUD.md`
  - WIF, OIDC, Secret Manager, IAM, and Google Cloud configuration

- `CONTRACT.md`
  - caller/shared-layer responsibility boundary

- `PROTOCOL.md`
  - Issue, Codex, Pull Request, review, and decision workflow

- `SECURITY.md`
  - credential handling and security invariants

- `OPERATIONS.md`
  - execution lifecycle, failures, and recovery

Read all documents materially relevant to the change before implementation.

## Security invariants

The following rules must remain true unless the architecture is explicitly redesigned and approved:

- use GitHub-hosted runners
- use GitHub OIDC and Google Cloud Workload Identity Federation
- do not introduce long-lived downloaded Google service account keys
- do not commit `auth.json`
- do not print `auth.json`, access tokens, refresh tokens, Secret payloads, or Google credentials
- keep caller authentication secrets isolated by repository
- use immutable GitHub identity attributes where defined
- keep reusable workflow references pinned to approved immutable commit SHAs
- apply least privilege to GitHub and Google Cloud permissions
- do not allow concurrent Codex jobs to use the same serialized authentication state
- preserve a known-good authentication state when candidate authentication validation fails

## Caller boundary

Application repositories define what should be built.

`codex-automation` defines how Codex is executed safely and consistently.

Do not introduce application-specific product architecture or application-specific decisions into this repository.

Caller-specific behavior should remain in the caller repository unless it is genuinely part of the shared automation contract.

## Change safety

Before making a change:

1. inspect the current repository state
2. confirm the expected branch and upstream state
3. inspect the files that will be changed
4. identify the intended diff
5. avoid modifying unrelated files

After making a change:

1. inspect the final diff
2. run applicable validation
3. confirm no unintended files changed
4. report exactly what changed
5. report any remaining uncertainty or incomplete validation

Do not hide unexpected repository state by automatically resetting, cleaning, rebasing, or force-pushing.

If unexpected state affects safety, stop and report it.

## Phase transitions

Completing an implementation step does not automatically authorize starting the next phase.

A phase transition should occur only after:

1. the current phase completion criteria in `ROADMAP.md` are satisfied
2. the result has been reviewed
3. the roadmap status is updated when appropriate
4. the user has explicitly agreed to proceed

When reporting completion of work associated with a roadmap phase, state:

- the phase
- what was completed
- whether all completion criteria are satisfied
- whether the phase is ready to be marked complete
- what the next authoritative phase is according to `ROADMAP.md`

## Principle

When repository state, conversation context, and remembered plans disagree:

> The current repository documentation is authoritative.

If the documentation itself appears inconsistent, stop and surface the inconsistency instead of silently choosing a new interpretation.
