# codex-automation

A reusable automation layer connecting ChatGPT, GitHub, and Codex across multiple repositories.

## Overview

`codex-automation` is a shared automation foundation for a development flow built around:

User
↕
ChatGPT
↕
GitHub
↕
Codex

The goal is to allow multiple GitHub repositories to use the same Codex execution infrastructure without duplicating authentication, security, workflow, and operational logic in every project.

Each application repository owns **what should be built**.

`codex-automation` owns **how Codex is executed safely and consistently**.

## Responsibilities

`codex-automation` is responsible for:

- reusable GitHub Actions workflows
- Codex CLI execution lifecycle
- authentication lifecycle
- Google Cloud Workload Identity Federation integration
- Secret Manager integration
- serialized Codex execution
- shared Issue / PR / Decision protocol
- security policy
- failure and recovery procedures
- the contract between caller repositories and the shared automation layer

Individual application repositories remain responsible for:

- application source code
- project-specific requirements
- project-specific `AGENTS.md`
- GitHub Issues describing work
- Pull Requests containing project changes
- project-specific architecture and decisions
- project-specific `DECISIONS.md` or equivalent records

## Status

Implementation is in progress.

The foundational execution path has been validated through:

- GitHub Actions reusable workflow execution
- GitHub OIDC
- Google Cloud Workload Identity Federation
- caller-specific Secret Manager access
- Codex `auth.json` restoration
- ChatGPT-authenticated Codex CLI execution
- a real read-only Codex task against a caller repository

The authoritative implementation phases, current project position, completion criteria, and next planned work are maintained in:

- `ROADMAP.md`

Do not infer the current phase from this README alone.

## Repository model

Example:

    interest-gacha
        |
        | thin caller workflow
        v
    codex-automation
        |
        | reusable workflow
        v
    GitHub-hosted runner
        |
        +--> Google Cloud Workload Identity Federation
        |
        +--> Secret Manager
        |
        +--> Codex CLI
        |
        v
    interest-gacha branch / Pull Request

## Documentation

- `ROADMAP.md`
  - authoritative implementation phases, current position, and completion criteria

- `AGENTS.md`
  - repository-level instructions for Codex and other implementation agents

- `ARCHITECTURE.md`
  - overall architecture and component responsibilities

- `GOOGLE_CLOUD.md`
  - Google Cloud / Workload Identity Federation / Secret Manager architecture

- `CONTRACT.md`
  - interface between caller repositories and `codex-automation`

- `PROTOCOL.md`
  - Issue / Codex / PR / Decision operating protocol

- `SECURITY.md`
  - authentication and security rules

- `OPERATIONS.md`
  - operational lifecycle, failures, and recovery

## Roadmap authority

`ROADMAP.md` is the single source of truth for:

- phase numbering
- phase names
- phase order
- phase completion state
- the current implementation position

Phase structure should not be changed only in conversation or an individual implementation session.

Changes to the roadmap should be explicitly proposed, reviewed, and reflected in `ROADMAP.md`.

## Agent workflow

Codex and other implementation agents working on this repository should begin by reading:

1. `AGENTS.md`
2. `ROADMAP.md`
3. the design documents relevant to the requested task

This keeps implementation aligned with the same project state used by the User and ChatGPT.

## Public repository policy

This repository is primarily maintained for personal use and is published as a reference implementation.

It may be useful to others building similar ChatGPT / GitHub / Codex automation systems, but maintenance, support, Issue handling, or external contribution review is not guaranteed.

GitHub Issues and Pull Requests for this repository may therefore remain disabled.
