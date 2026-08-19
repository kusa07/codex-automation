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

This repository is currently in the **design phase**.

The initial version intentionally contains architecture and operational documentation only.

GitHub Actions workflows, scripts, and Google Cloud infrastructure will be implemented after the design is reviewed and stabilized.

## Repository model

Example:

```text
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
```

## Documentation

- `ARCHITECTURE.md`
  - overall architecture and component responsibilities
- `GOOGLE_CLOUD.md`
  - Google Cloud / Workload Identity Federation / Secret Manager architecture
- `CONTRACT.md`
  - interface between caller repositories and codex-automation
- `PROTOCOL.md`
  - Issue / Codex / PR / Decision operating protocol
- `SECURITY.md`
  - authentication and security rules
- `OPERATIONS.md`
  - operational lifecycle, failures, and recovery

## Public repository policy

This repository is primarily maintained for personal use and is published as a reference implementation.

It may be useful to others building similar ChatGPT / GitHub / Codex automation systems, but maintenance, support, Issue handling, or external contribution review is not guaranteed.

GitHub Issues and Pull Requests for this repository may therefore remain disabled.
