# Phase 12B Caller Onboarding / Host Recovery Design

## 1. Purpose

This document defines the Phase 12B design for multi-repository caller onboarding, host recovery, caller offboarding, and repeatable operation of `codex-automation`.

The design extends the existing shared automation architecture without changing the Phase 12A return-loop model or the existing Google Cloud trust boundary.

Goals:

- add a new caller repository with minimal manual work
- keep caller-specific Secret Manager and IAM isolation
- use repository-scoped self-hosted runners for caller dispatch isolation
- keep one shared Self-hosted Execution Area serialized by the local Global Mutex
- keep host-specific and personal configuration out of the public repository
- make a replacement Windows PC reconstructible from GitHub configuration plus Google Secret Manager
- keep credentials and authentication payloads out of Git
- automate normal, mechanically verifiable operations
- fail closed when actual state is ambiguous or inconsistent
- support explicit caller offboarding and host migration

The intended steady-state operator experience is:

```text
new caller
    ↓
onboard-caller.sh <owner/repository>
    ↓
read-only grounding
    ↓
one consolidated plan / approval
    ↓
Secret / IAM / caller workflow / runner / auth setup
    ↓
read-back verification
    ↓
CALLER_ONBOARDING RESULT=PASS
```

A replacement host should be recoverable through:

```text
new Windows PC
    ↓
clone public codex-automation repository
    ↓
clone private configuration repository
    ↓
interactive bootstrap authentication
    ↓
bootstrap-host.ps1
    ↓
verify-host.ps1
    ↓
HOST_RECOVERY RESULT=PASS
```

---

## 2. Responsibility model

The Phase 12B operational model has four persistent layers plus one administrative identity.

```text
Public GitHub repository
kusa07/codex-automation
    = HOW
    common code / templates / validation / policy

Private GitHub repository
kusa07/codex-automation-private
    = DESIRED STATE
    host and caller configuration

Local Windows host
    = REGENERATABLE RUNTIME
    runner instances / execution area / runtime state / local ACL

Google Secret Manager
    = SECRET / AUTHENTICATION STATE
    caller-specific Codex auth.json

Bootstrap Operator
    = INITIAL / ADMIN CONTROL
    gh auth login + gcloud auth login
```

The private repository is not a secret store. It must contain configuration values and desired state only.

No repository, public or private, stores:

- Codex `auth.json`
- access tokens
- refresh tokens
- GitHub runner registration tokens
- Google credential files
- other reusable credential payloads

---

## 3. Identity model

Four identities must remain distinct.

| Identity | Purpose | Lifetime | Source of truth / storage | Recovery |
|---|---|---|---|---|
| Bootstrap Operator | GitHub and Google Cloud administrative setup | interactive session | `gh` / `gcloud` login state | log in again |
| Runner Service Identity | execute Windows runner services | persistent | Windows built-in account | present on Windows |
| Runner Registration Identity | bind one runner instance to one caller repository | runner-instance lifetime | local runner registration state | re-register runner |
| Codex Authentication | authenticate Local Codex through ChatGPT login | ongoing | caller-specific Google Secret Manager secret | restore from Secret Manager |

These identities must not be treated as interchangeable.

---

## 4. Runner Service Identity

Phase 12B standardizes the Windows self-hosted runner service identity as:

```text
NT AUTHORITY\NETWORK SERVICE
SID: S-1-5-20
```

This is a Windows built-in service identity. It is not an IP address and is independent of DHCP or local network addressing.

The current design must remove dependence on a personal or machine-specific user SID from shared public code.

The allowed Mutex principal and local filesystem ACL policy must be based on the approved service identity rather than a personal Windows account.

---

## 5. Public repository structure

The public `kusa07/codex-automation` repository remains the authoritative location for reusable implementation logic.

Target structure:

```text
codex-automation/
├─ .github/
│  └─ workflows/
│     └─ codex-run.yml
├─ templates/
│  └─ caller/
│     └─ codex-connectivity-test.yml.tpl
├─ scripts/
│  ├─ onboarding/
│  │  ├─ onboard-caller.sh
│  │  └─ offboard-caller.sh
│  ├─ host/
│  │  ├─ bootstrap-host.ps1
│  │  ├─ verify-host.ps1
│  │  └─ migrate-host.ps1
│  ├─ google-cloud/
│  │  └─ existing Google Cloud helpers
│  └─ self-hosted/
│     └─ existing Self-hosted Execution helpers
└─ config-example/
   ├─ environment.yaml
   ├─ hosts/
   │  └─ main-windows.yaml
   └─ callers/
      └─ example-project.yaml
```

Public code must not embed personal host details such as a user SID, personal username, PC name, or private user-profile path.

Generic infrastructure paths are acceptable when they are part of the documented platform contract rather than personal information.

---

## 6. Private configuration repository

Create a private repository such as:

```text
kusa07/codex-automation-private
```

Its role is to preserve Desired State required to rebuild the environment.

Target structure:

```text
codex-automation-private/
├─ environment.yaml
├─ hosts/
│  └─ main-windows.yaml
├─ callers/
│  ├─ interest-gacha.yaml
│  └─ chatgpt-voicevox-edge.yaml
├─ retired-callers/
└─ RECOVERY.md
```

### Example environment configuration

```yaml
schema_version: 1

github:
  owner: kusa07

google_cloud:
  project_id: codex-automation-506111
  workload_identity_pool: github
  workload_identity_provider: github-actions

codex_automation:
  repository: kusa07/codex-automation
  reusable_workflow:
    path: .github/workflows/codex-run.yml
    approved_sha: 352857a387b1f855920fb8d1587091b31e518c21

host:
  config: hosts/main-windows.yaml
```

### Example host configuration

```yaml
schema_version: 1

host_id: main-windows-runner
platform: windows

paths:
  execution_root: C:\codex-self-hosted
  runner_root: C:\codex-runners
  runtime_root: C:\ProgramData\CodexAutomation

runner:
  mode: windows-service
  service_identity: network-service
  labels:
    - self-hosted
    - Windows
    - X64
    - codex-automation

execution:
  serialization: global-mutex
```

### Example caller configuration

```yaml
schema_version: 1

repository:
  full_name: kusa07/chatgpt-voicevox-edge
  id: 1350660842

secret:
  id: codex-auth-chatgpt-voicevox-edge

workflow:
  path: .github/workflows/codex-connectivity-test.yml

runner:
  enabled: true
  scope: repository
```

The immutable GitHub repository ID is the primary caller identity. A name change must not silently change authorization identity.

---

## 7. Canonical caller workflow template

Caller workflows remain thin adapters.

The public repository should contain a canonical template:

```text
templates/caller/codex-connectivity-test.yml.tpl
```

`onboard-caller.sh` renders the caller workflow from this template and validates an existing caller workflow against the expected rendered output.

Caller-specific values may include:

- reusable workflow immutable SHA
- Google Cloud Project ID
- WIF Provider
- event trigger

Shared execution, authentication lifecycle, publication logic, and Self-hosted Execution behavior remain owned by `codex-automation`.

Unexpected differences in an existing caller workflow must stop onboarding rather than being overwritten automatically.

---

## 8. Bootstrap Operator authentication

The following scripts require an authenticated Bootstrap Operator before mutation:

- `bootstrap-host.ps1`
- `onboard-caller.sh`
- `offboard-caller.sh`
- `migrate-host.ps1`

Each script must confirm appropriate GitHub and Google Cloud access before making changes.

Conceptually:

```text
gh auth status
    ↓
required GitHub administrative access confirmed

gcloud authenticated account
    ↓
required codex-automation project permissions confirmed
```

Expected status contract:

```text
GH_BOOTSTRAP_AUTH=PASS
GCP_BOOTSTRAP_AUTH=PASS
```

WIF is not the bootstrap identity. WIF remains the normal GitHub Actions → Google Cloud runtime authentication path.

---

## 9. Host bootstrap and classification

`bootstrap-host.ps1` is responsible for initial host setup and safe verification/completion of an already bootstrapped host.

It must not infer that a missing directory is always a new host.

Host state is classified from both runtime state and the managed execution root.

### A. runtime absent / execution root absent

```text
NEW HOST
```

Creation is allowed.

### B. runtime present / execution root present

```text
EXISTING HOST
```

Validate marker, schema, identity, residual state, ACL, runner state, and required tools.

### C. runtime present / execution root absent

```text
INCONSISTENT HOST
```

Stop. This may indicate accidental deletion or incomplete recovery.

### D. runtime absent / execution root present

Validate the existing managed-area marker.

A valid known managed area may be treated as a recovery candidate. Missing, malformed, unsupported, or inconsistent markers stop the operation.

Normal bootstrap must not silently normalize ambiguous persistent state.

---

## 10. Execution Area invariants

New managed execution areas are created only after the host is classified as NEW.

Creation includes:

```text
execution root
    ↓
ownership marker
    ↓
schema version
    ↓
execution_area_id
    ↓
required directories
    ↓
NETWORK SERVICE ACL
    ↓
preflight
```

Existing managed areas require validation of at least:

- ownership marker
- marker structure
- supported schema
- execution-area identity
- known entries only
- no active execution residue
- no credential residue
- expected filesystem ACL
- local lock compatibility

Ambiguity remains fail closed, consistent with the existing Self-hosted Execution architecture.

---

## 11. Automation service profile and CLI environment

`NETWORK SERVICE` must not depend on the interactive user's profile or per-user CLI configuration.

Phase 12B therefore defines automation-owned service-profile paths under a stable runtime root such as:

```text
C:\ProgramData\CodexAutomation\
├─ profile\
├─ gh\
├─ npm-cache\
├─ runtime.json
└─ audit\
```

The service execution environment must explicitly define the locations required by CLI tools. The exact implementation may use variables such as:

```text
HOME=C:\ProgramData\CodexAutomation\profile
GH_CONFIG_DIR=C:\ProgramData\CodexAutomation\gh
npm_config_cache=C:\ProgramData\CodexAutomation\npm-cache
CODEX_HOME=<automation-managed Codex home>
```

The implementation must not assume the interactive user's:

- `%USERPROFILE%`
- `.gitconfig`
- gh configuration
- npm cache/configuration
- Codex home

Bootstrap/preflight must verify that required executables and runtime locations are accessible under the runner service context.

Sensitive bootstrap credentials must not be copied into this service profile. Normal workflow authentication continues to use GitHub runtime credentials and WIF as designed.

---

## 12. Repository-scoped runner model

Phase 12B standardizes one repository-scoped runner instance per active caller.

Example local layout:

```text
C:\codex-runners\
├─ interest-gacha\
└─ chatgpt-voicevox-edge\
```

Each runner:

- is registered only to its caller repository
- uses the approved runner labels
- runs as a Windows Service
- uses `NT AUTHORITY\NETWORK SERVICE`
- is reconstructible and may be re-registered on a replacement PC

Old runner registration credentials are not backed up into Git. A replacement host re-registers runner instances.

### Runner-instance state classification

Runner state is evaluated per caller.

#### NEW

```text
local runner absent
GitHub runner registration absent
```

Creation/registration is allowed.

#### EXISTING

All of the following agree:

- local runner instance exists
- Windows Service exists
- GitHub registration exists
- repository identity matches
- labels match policy
- service identity matches `NETWORK SERVICE`

Reuse is allowed.

#### INCONSISTENT

Examples:

- local runner exists but GitHub registration is absent
- GitHub registration exists but local runner is absent
- Windows Service is missing
- runner is bound to the wrong repository
- labels differ unexpectedly
- service identity differs from policy

Normal bootstrap/onboarding stops. Automatic destructive re-registration is not performed from an ambiguous state.

---

## 13. Shared local execution and caller isolation boundary

Caller isolation exists at multiple layers, but Phase 12B does not claim complete OS-level isolation between callers on the same host.

```text
Google Cloud:
caller-specific Secret + repository-ID IAM
    = separate authorization boundary

GitHub:
repository-scoped runner
    = separate dispatch boundary

Local Windows host:
NETWORK SERVICE + shared Execution Area
    = shared local trust domain
```

All caller runners converge on the same Self-hosted Execution Area and the same local service identity.

Therefore, compromise of the shared Windows host or the `NETWORK SERVICE` trust domain is outside the guarantee provided by caller-specific Secret/IAM separation.

The initial design mitigates normal cross-run contamination through:

- one active local job at a time
- Global Mutex
- run-specific workspaces
- bounded credential/runtime locations
- credential cleanup
- pre-run and post-run residual-state validation
- fail-closed behavior for ambiguous state

If stronger caller isolation is later required, possible future designs include separate Windows identities, separate VMs, or separate physical hosts. Those are not Phase 12B requirements.

---

## 14. Shared Execution Area and serialization

Repository-scoped runners remain independently queueable at the GitHub Actions layer.

All caller executions remain globally serialized locally:

```text
runner-interest-gacha ─────┐
                            ├─ Global Mutex
runner-voicevox-edge ──────┘
                                   ↓
                         C:\codex-self-hosted
                                   ↓
                              Local Codex
```

No additional shared queue service is introduced.

The Mutex ACL must grant only the approved service identity required for normal execution. The implementation must not weaken ACL policy as an automatic fallback.

---

## 15. `onboard-caller.sh`

This is the primary user-facing caller-addition command.

Conceptual invocation:

```text
./scripts/onboarding/onboard-caller.sh \
  --repository kusa07/chatgpt-voicevox-edge \
  --private-config ../codex-automation-private
```

Flow:

```text
Bootstrap Operator authentication check
    ↓
load and validate private configuration
    ↓
read GitHub repository metadata
    ↓
resolve / verify immutable repository ID
    ↓
read-only current-state grounding
    ↓
render consolidated onboarding plan
    ↓
one operator approval
    ↓
Secret create/verify
    ↓
Secret-level IAM create/verify
    ↓
caller workflow render/create/verify
    ↓
runner state classify/register/verify
    ↓
Windows Service configure/verify
    ↓
initial Codex auth seed if required
    ↓
full read-back
    ↓
CALLER_ONBOARDING RESULT
```

Normal known-good operations should continue without per-step prompts after the consolidated plan approval.

---

## 16. Onboarding plan and STOP conditions

Before mutation, onboarding displays the complete intended change set.

Example:

```text
CALLER_ONBOARDING_PLAN

REPOSITORY=kusa07/chatgpt-voicevox-edge
REPOSITORY_ID=1350660842
SECRET=codex-auth-chatgpt-voicevox-edge
WORKFLOW=.github/workflows/codex-connectivity-test.yml
RUNNER_SCOPE=repository
RUNNER_SERVICE_IDENTITY=NT AUTHORITY\NETWORK SERVICE
EXECUTION_ROOT=C:\codex-self-hosted
REUSABLE_WORKFLOW_SHA=<approved immutable SHA>
AUTH_SEED=trusted local Codex login
```

Stop rather than auto-repair when examples such as the following are observed:

- repository ID differs from configured identity
- Secret IAM differs from expected repository-specific binding
- multiple Secret versions are enabled
- an existing caller workflow unexpectedly differs from canonical output
- WIF trust state differs from expected policy
- runner instance is inconsistent
- execution-area marker/schema is inconsistent
- runtime state indicates a missing execution area
- credential residue is present
- service identity or ACL differs unexpectedly
- Codex authentication is not recognized as a ChatGPT login
- private configuration schema is unsupported

Result contract:

```text
RESULT=STOP
EXPECTED=...
ACTUAL=...
NEXT_ACTION=USER_DECISION
```

---

## 17. Caller Secret and authentication lifecycle

Existing Google Cloud architecture remains authoritative:

- one shared Google Cloud Project
- one shared WIF Pool
- one shared GitHub OIDC Provider
- one Secret per caller
- repository-ID-specific Secret IAM

Examples:

```text
interest-gacha
    → codex-auth-interest-gacha

chatgpt-voicevox-edge
    → codex-auth-chatgpt-voicevox-edge
```

The onboarding helper may automate the trusted-host initial seed, but must preserve the established security invariants:

```text
trusted local auth.json
    ↓
codex login status confirms ChatGPT login
    ↓
add candidate Secret version
    ↓
read back exact version
    ↓
verify bytes without logging payload or digest
    ↓
validate read-back as ChatGPT login
    ↓
verify exactly one enabled authoritative version
```

Authentication payloads, tokens, hashes, or Secret contents must not be logged or committed.

---

## 18. `offboard-caller.sh`

Caller retirement must be a first-class operation.

Flow:

```text
Bootstrap Operator authentication check
    ↓
read-only current-state grounding
    ↓
offboarding plan
    ↓
one operator approval
    ↓
stop runner service
    ↓
unregister runner
    ↓
remove/disable caller workflow
    ↓
revoke caller Secret IAM
    ↓
disable Secret versions
    ↓
read-back verification
    ↓
move caller configuration to retired-callers
```

Secret versions are not permanently destroyed as part of normal offboarding. Permanent destruction requires a separate explicit operation after an appropriate retention/review decision.

---

## 19. Explicit host migration

Normal bootstrap and verify operations do not silently change established host identity or core layout.

Intentional changes use an explicit migration command:

```text
migrate-host.ps1
```

Examples:

- execution-root move
- runner-root move
- service-identity policy change
- execution-area schema migration
- runner architecture change

Migration flow:

```text
current-state grounding
    ↓
migration plan
    ↓
one operator approval
    ↓
migration
    ↓
full verification
```

There is no implicit "migration mode" exception inside normal bootstrap.

---

## 20. Runtime state and audit

Regeneratable local state is stored outside Git, for example:

```text
C:\ProgramData\CodexAutomation\
├─ runtime.json
├─ profile\
├─ gh\
├─ npm-cache\
└─ audit\
   └─ operations.jsonl
```

`runtime.json` records only runtime identity/configuration needed to detect inconsistent host state. It is not authoritative over the private Desired State repository.

Security-sensitive onboarding, offboarding, migration, and recovery operations emit sanitized local audit entries.

Audit sources are layered:

```text
local sanitized operation log
+
Google Cloud Audit Logs
+
GitHub commit / repository history
```

Local audit must not include:

- Secret payloads
- auth.json
- access/refresh tokens
- Google credential contents
- authentication hashes

Local logs are supplementary and are not the only audit trail for security-relevant changes.

---

## 21. `verify-host.ps1`

`verify-host.ps1` performs a non-destructive health check over the host and configured callers.

Expected output shape:

```text
HOST_VERIFY
RESULT=PASS

PUBLIC_REPO=PASS
PRIVATE_CONFIG=PASS
RUNNER_SERVICE_IDENTITY=PASS
SERVICE_PROFILE=PASS
EXECUTION_AREA=PASS
EXECUTION_MARKER=PASS
EXECUTION_ACL=PASS
MUTEX_ACL=PASS
WIF=PASS

CALLERS=2

interest-gacha:
  REPOSITORY_ID=PASS
  SECRET=PASS
  IAM=PASS
  RUNNER=PASS
  WORKFLOW=PASS

chatgpt-voicevox-edge:
  REPOSITORY_ID=PASS
  SECRET=PASS
  IAM=PASS
  RUNNER=PASS
  WORKFLOW=PASS

NEXT_ACTION=READY
```

Credential payloads are never displayed.

---

## 22. Host recovery

A replacement PC recovery process is intentionally reconstructive rather than a raw backup/restore of runtime credentials.

Conceptual procedure:

```text
1. prepare Windows
2. install required tools
3. clone kusa07/codex-automation
4. clone kusa07/codex-automation-private
5. gh auth login
6. gcloud auth login
7. run bootstrap-host.ps1
8. run verify-host.ps1
```

Bootstrap reconstructs or re-registers:

- managed execution area
- marker/schema state
- local ACL
- automation service profile
- runtime metadata
- repository-scoped runner instances
- Windows runner services
- caller wiring

Codex authentication state remains authoritative in Google Secret Manager and is restored through the normal approved lifecycle.

Old runner registration credentials are not copied from the failed machine.

---

## 23. Return Hub boundary

ChatGPT Work Return Hub remains outside local host bootstrap/onboarding automation.

Successful caller onboarding ends with an explicit operational handoff such as:

```text
NEXT_ACTION=CONFIGURE_RETURN_HUB
```

The existing return-loop model remains:

```text
Draft PR opened
    ↓
Work event trigger
    ↓
GitHub read-back
    ↓
CODEX_RETURN_E2E
```

Return Hub automation may be reconsidered only when a safe supported management interface exists.

---

## 24. Implementation order

Recommended Phase 12B implementation order:

1. define private configuration schema
2. remove public-code dependence on personal host SID and other host-specific values
3. add canonical caller workflow template
4. implement `bootstrap-host.ps1`
   - Bootstrap Operator validation
   - host classification
   - execution marker/schema handling
   - NETWORK SERVICE ACL
   - automation-owned CLI/service profile
   - runner instance classification and Windows Service handling
5. implement `verify-host.ps1`
6. implement minimal explicit `migrate-host.ps1` framework
7. implement `onboard-caller.sh`
8. implement `offboard-caller.sh`
9. create private Desired State repository
10. record existing `interest-gacha` caller state
11. migrate the current interest-gacha runner to the Phase 12B host policy if required
12. add `chatgpt-voicevox-edge` Desired State
13. use `onboard-caller.sh` as the first real multi-repository onboarding
14. run a low-risk real Issue → Codex → Draft PR E2E
15. add `chatgpt-voicevox-edge` to the existing Return Hub
16. validate caller isolation and local cleanup behavior
17. validate host recovery path
18. update authoritative roadmap/documentation only after validated implementation results

---

## 25. Phase 12B completion criteria

Phase 12B may be considered complete when all of the following are true:

- at least two caller repositories use the shared infrastructure
- each caller has an independent Secret
- Secret IAM is isolated by immutable repository ID
- each caller has a repository-scoped runner
- runner services use the approved `NETWORK SERVICE` identity
- runner services recover automatically after Windows reboot without interactive login
- service execution does not depend on the interactive user's CLI profile
- callers share the reusable workflow rather than duplicating orchestration logic
- callers share the managed Self-hosted Execution Area
- local Local Codex execution remains globally serialized
- caller onboarding is available through the onboarding automation
- caller offboarding is explicitly supported
- personal SID dependence is removed from public shared code
- private GitHub Desired State plus Secret Manager can reconstruct a replacement host
- credential material is absent from Git
- Bootstrap Operator access is explicitly separated from runtime WIF/Codex identities
- marker/schema/residual-state fail-closed behavior remains intact
- host and runner-instance inconsistencies are detected rather than silently repaired
- migration is an explicit operation
- onboarding/recovery/offboarding have sanitized auditability
- `chatgpt-voicevox-edge` completes Issue → Codex → Draft PR
- Return Hub independently reads back the resulting PR
- adding another caller no longer requires architectural redesign

---

## 26. Design principles

1. Automate normal operations that can be mechanically verified afterward.
2. Keep human approval at meaningful decision or high-value plan boundaries rather than at every step.
3. Never store authentication payloads in Git, including private Git repositories.
4. Treat immutable repository ID as the primary caller authorization identity.
5. Preserve caller-specific Secret/IAM boundaries.
6. Use repository-scoped runner registration as the Phase 12B GitHub dispatch isolation boundary.
7. Be explicit that the shared Windows host remains one local trust domain.
8. Never trust persistent local state solely because a path exists.
9. Keep marker/schema/residual-state checks fail closed.
10. Use `NT AUTHORITY\NETWORK SERVICE` as the standard runner service identity.
11. Make CLI/profile locations explicit for the service context rather than inheriting an interactive user's profile.
12. Keep private GitHub content declarative; reusable logic remains public in `codex-automation`.
13. Keep normal bootstrap separate from explicit migration.
14. Do not require shared-automation code changes for each new caller.
15. Preserve reconstructability: GitHub stores desired configuration, Secret Manager stores authentication state, and local runtime state is reproducible.
