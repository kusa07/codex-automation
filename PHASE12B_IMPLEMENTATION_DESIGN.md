# Phase 12B Batch A — Shared Foundation

This document records the implementation boundary for Batch A. The higher
level design is the immutable reference
`d6b56ec250615c7d4c0b3ab5f476632c7c14240f` on branch
`docs/phase12b-onboarding-host-recovery-design`.

## Boundary

Batch A adds public desired-state examples, canonical workflow rendering,
state classifiers, and plan-gated operator entry points. It does not change a
caller pin, stage or finalize WIF, create a private configuration repository,
migrate a host, register a runner, or onboard/offboard a live caller.

## Desired state and identity

YAML is parsed only through a supported `yq`; no shell YAML parser or fallback
is permitted. Repository ID is the caller's primary immutable identity. A
configured Secret ID is literal data and is never derived from a repository
name. The environment's active workflow SHA is the caller rollout SHA, not a
description of the complete WIF allow-list.

## Host policy

The standard runner service identity is `NT AUTHORITY\\NETWORK SERVICE`
(`S-1-5-20`). Runtime data belongs in
`C:\\ProgramData\\CodexAutomation`; execution state remains in the existing
managed execution area. The host and each repository-scoped runner classify as
`NEW`, `EXISTING`, or `INCONSISTENT`. Unknown, reparse, malformed, ACL-drift,
or partial state is `INCONSISTENT` and must stop rather than be repaired.

Host bootstrap and migration are separate plan-gated operations. Migration
requires quiescence: no active or queued workflow, local execution, held
Global Mutex, or residual execution state.

## Caller workflow synchronization

The canonical template has the immutable automation SHA, project, provider,
and literal Secret ID. A caller workflow is `ABSENT`, `EXACT_TARGET`,
`MANAGED_OLD`, or `DIVERGED`. Only a known canonical old template can become
an approved full-template upgrade; divergent files are never overwritten.
`ABSENT` remains an onboarding plan candidate in Batch A rather than an
automatic workflow creation path.

## Rollout order

After Batch A is reviewed and merged, a later operation creates the immutable
workflow SHA, runs `rotate-workflow-sha.sh stage`, prepares private desired
state, migrates under quiescence, runs host verification, synchronizes caller
workflows, performs a bounded E2E, and only then may run
`rotate-workflow-sha.sh finalize --confirm-remove-old`. Batch A performs none
of these production changes.
