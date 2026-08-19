# Development Protocol

## 1. Purpose

This document defines the shared operating protocol between:

- User
- ChatGPT
- GitHub
- Codex

It defines how work moves through the system.

It does not contain application-specific decisions.

## 2. Core flow

The standard flow is:

```text
User
  ↓
ChatGPT discussion
  ↓
GitHub Issue
  ↓
Issue becomes implementation-ready
  ↓
codex-ready
  ↓
Codex execution
  ↓
branch / commits
  ↓
Pull Request
  ↓
review
  ↓
merge decision
```

## 3. Issue role

A GitHub Issue represents a unit of requested work.

Before being marked `codex-ready`, an Issue should be sufficiently clear that Codex can act without inventing important product decisions.

An Issue may contain:

- objective
- background
- constraints
- acceptance criteria
- affected components
- relevant existing decisions
- explicit non-goals

The Issue does not need to prescribe low-level implementation details unless those details are intentional requirements.

## 4. codex-ready

The `codex-ready` label has one precise meaning:

> This Issue is ready to be handed to Codex for execution.

It does NOT mean:

- the implementation is correct
- the resulting Pull Request is approved
- the Pull Request may be merged automatically
- architectural review is complete

`codex-ready` is an execution authorization signal, not a merge authorization signal.

## 5. Codex role

Codex is responsible for implementing the Issue within the constraints of:

1. the Issue
2. repository-local instructions such as `AGENTS.md`
3. existing code and tests
4. existing project decisions

Codex should not silently redefine product requirements.

If an important ambiguity cannot be resolved safely from the repository context, execution should fail or report the ambiguity rather than inventing a major decision.

## 6. Pull Request role

Codex output should normally be surfaced through a Pull Request in the caller repository.

The Pull Request is the review boundary.

A Pull Request should make it possible to understand:

- what changed
- why it changed
- which Issue it addresses
- what validation was performed
- any unresolved limitations

## 7. Review role

The user and/or ChatGPT review the Pull Request.

Review may compare the proposed change against:

- original Issue intent
- current architecture
- tests
- previous project decisions
- new trade-offs discovered during implementation

Codex execution does not replace review.

## 8. Decision records

This repository defines when and why decisions should be recorded, but application-specific decisions belong in the application repository.

Examples:

```text
codex-automation/PROTOCOL.md
    -> defines HOW decisions are recorded

interest-gacha/DECISIONS.md
    -> contains the actual decisions for interest-gacha
```

A decision record is useful when:

- multiple plausible designs existed
- a trade-off was intentionally accepted
- a future developer or ChatGPT session might otherwise propose a contradictory solution
- understanding why something was chosen matters for future changes

Routine implementation details do not automatically require a permanent decision record.

## 9. Future comparison

When a new proposal conflicts with an earlier recorded decision, the old decision should not be treated as immutable law.

Instead:

1. read the previous decision and its reasoning
2. understand what has changed
3. compare the old and new trade-offs
4. decide whether the previous decision still applies
5. update or supersede the decision record when appropriate

The value of decision history is preserving reasoning, not preventing change.

## 10. Human authority

Automation may prepare, implement, validate, and summarize work.

Final authority over product direction and merge decisions remains with the user unless explicitly delegated later.
