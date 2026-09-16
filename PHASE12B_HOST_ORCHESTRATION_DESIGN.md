# Phase 12B Host Orchestration 詳細設計 v0.4

**Status:** Reviewed / Implementation Ready  
**Scope:** Phase 12B Caller Onboarding / Offboarding と Windows Host Orchestration の責務境界  
**Repository:** `kusa07/codex-automation`

---

## 1. 目的

本設計は、Phase 12B における caller onboarding / offboarding と、Windows 上の repository-scoped GitHub Actions runner および Windows Service の管理境界を定義する。

既存の Phase 12B 設計、Google Cloud trust boundary、Self-hosted Execution architecture、trusted publication boundary は変更しない。

本設計で解決する主な問題は以下である。

- caller lifecycle が runner / service の状態を任意の環境変数から受け取らないこと
- production mutation を任意 command adapter へ委譲しないこと
- actual state を read-back して fail closed すること
- Onboard / Offboard の途中で失敗しても、安全に再開可能であること
- runtime metadata と actual state の不整合から安全に復旧できること
- production / test 境界を明確化すること
- caller lifecycle と host orchestration の責務を固定すること
- shared Global Mutex を caller 単位の execution ownership と合わせて正しく判定すること
- host-level state と caller-runner-level state の用語を明確に分離すること

本設計では、fail-closed を「停止するだけ」の仕組みにせず、停止後の安全な再開・復旧経路まで定義する。

---

## 2. 基本設計原則

Production の authority は以下から構成する。

```text
environment desired state
        +
host desired state
        +
caller desired state
        +
actual GitHub / Windows / Google Cloud state
```

Production では、以下を authority として使用してはならない。

```text
operator-controlled environment variables
arbitrary shell commands
caller-controlled executable paths
fake runner state
fake service state
Secret version override
workflow state override
test adapter output
```

Test では fake state を利用してよいが、明示的な Test Mode と isolated fixture root の下でのみ許可する。

Production で test-only mechanism が検出された場合は無視して続行せず STOP する。

---

## 3. Desired State の責務

### 3.1 environment.yaml

Environment 全体に共通する desired state を持つ。

主な項目:

```text
GitHub owner
Google Cloud project
WIF Provider
codex-automation repository
reusable workflow path
active workflow SHA
host configuration reference
```

Host configuration は environment から一意に解決する。

例:

```yaml
host:
  config: hosts/main-windows.yaml
```

CLI から別 host を指定して authority を二重化しない。

### 3.2 host configuration

Windows host の desired state を持つ。

主な項目:

```text
host_id
platform
execution_root
runner_root
runtime_root
profile_root
runner mode
service identity
service SID
required runner labels
serialization policy
quiescence policy
```

例:

```yaml
schema_version: 1

host_id: main-windows-runner
platform: windows

paths:
  execution_root: C:\codex-self-hosted
  runner_root: C:\codex-runners
  runtime_root: C:\ProgramData\CodexAutomation
  profile_root: C:\ProgramData\CodexAutomation\profile

runner:
  mode: windows-service
  service_identity: network-service
  service_sid: S-1-5-20
  labels:
    - self-hosted
    - Windows
    - X64
    - codex-automation

execution:
  serialization: global-mutex
  quiescence_timeout_seconds: 600
```

`quiescence_timeout_seconds` は host policy とする。

未指定時の default は 600 秒とする。

Timeout は待機上限であり、実行中 job を kill する許可ではない。

Public / private configuration に以下を保存してはならない。

```text
personal username
personal SID
PC-specific interactive user profile
credential payload
runner registration token
GitHub token
Google credential
Codex auth payload
```

### 3.3 caller configuration

Caller 固有の desired state を持つ。

主な項目:

```text
repository full_name
immutable repository ID
Secret ID
caller workflow path
repository-scoped runner policy
```

Caller の primary identity は repository name ではなく immutable GitHub repository ID とする。

Repository rename は caller identity の変更として扱わない。

---

## 4. Caller CLI

Caller lifecycle のユーザー向け entry point は以下とする。

```text
onboard-caller.sh \
  --environment <environment.yaml> \
  --caller <caller.yaml>
```

```text
offboard-caller.sh \
  --environment <environment.yaml> \
  --caller <caller.yaml>
```

`--host` は追加しない。

理由は、environment が host configuration を一意に参照するためである。

処理開始時に以下を cross-validation する。

```text
environment → host reference
host schema
caller schema
repository ID
runner policy
service identity policy
workflow path
Secret ID
```

不一致は STOP とする。

---

## 5. Responsibility Boundary

全体責務は以下とする。

```text
onboard-caller.sh / offboard-caller.sh
             │
             │ lifecycle orchestration
             │ plan
             │ approval
             │ cloud/workflow coordination
             ▼
        caller-runner.ps1
             │
             │ thin CLI boundary
             ▼
       phase12b-host.psm1
             │
             │ snapshot inspection
             │ lifecycle state machine
             │ recovery decision
             │ validation
             │ host operations
             ▼
 GitHub Runner / Windows Service
```

### onboard-caller.sh / offboard-caller.sh

担当:

```text
desired state load
read-only grounding
complete plan generation
single approval gate
operation ordering
Cloud operation coordination
workflow coordination
Host Orchestration invocation
final verification
```

Windows Service や runner の内部操作ロジックは持たない。

### caller-runner.ps1

Thin CLI entry point とする。

担当:

```text
argument parsing
fixed Action dispatch
HostConfig loading
Repository identity validation
phase12b-host.psm1 invocation
structured result output
```

State machine や主要 business logic を `caller-runner.ps1` に重複実装しない。

### phase12b-host.psm1

Host Orchestration の logic owner とする。

担当:

```text
runner/service actual read-back
snapshot classification
lifecycle state machine
recovery decision
precondition validation
canonical host mutation
postcondition validation
recovery classification
runtime metadata handling
```

既存 Host / Runner classifier を拡張して使用する。

---

## 6. Canonical Host Orchestration Interface

Production entry point として以下を使用する。

```text
scripts/host/caller-runner.ps1
```

概念 interface:

```text
caller-runner.ps1
  -Action Inspect|Onboard|Offboard|Verify
  -HostConfig <file>
  -RepositoryFullName <owner/repository>
  -RepositoryId <immutable-id>
```

Test 時のみ:

```text
-TestMode
-FixtureRoot <temporary-path>
```

を許可する。

Test Mode は CLI flag でのみ有効化する。

Environment variable による自動 Test Mode 有効化は禁止する。

---

## 7. 状態体系と名前空間

Host-level state と caller-runner-level state を明確に分離する。

### 7.1 HOST_STATE

Host 全体の bootstrap / migration consistency を表す。

```text
HOST_STATE=NEW
HOST_STATE=EXISTING
HOST_STATE=INCONSISTENT
```

既存 host-level classifier の責務とする。

Caller runner lifecycle ではこの enum を再利用しない。

### 7.2 CALLER_RUNNER_SNAPSHOT_STATE

今この瞬間の caller runner に関する actual state と metadata の整合状況を表す。

```text
CALLER_RUNNER_SNAPSHOT_STATE=NEW
CALLER_RUNNER_SNAPSHOT_STATE=CONSISTENT
CALLER_RUNNER_SNAPSHOT_STATE=PARTIAL
CALLER_RUNNER_SNAPSHOT_STATE=CONFLICT
```

Snapshot State は静的観測結果であり、処理進捗そのものではない。

### 7.3 CALLER_RUNNER_LIFECYCLE_STATE

Operation がどこまで進んでいるかという intent / progress を表す。

Onboard:

```text
ABSENT
REGISTERING
REGISTERED
SERVICE_INSTALLING
SERVICE_INSTALLED
ACTIVE
```

Offboard:

```text
ACTIVE
RETIRING
DISPATCH_DISABLED
SERVICE_STOPPED
RUNNER_REMOVED
RETIRED
```

### 7.4 RECOVERY_DECISION

Snapshot State、Lifecycle State、actual state の組み合わせから、次に何をしてよいかを決める。

```text
RECOVERY_DECISION=RETRY_SAFE
RECOVERY_DECISION=RESUME_SAFE
RECOVERY_DECISION=RECOVER_WITH_APPROVAL
RECOVERY_DECISION=MANUAL_INTERVENTION_REQUIRED
```

3つの caller-runner 軸と `HOST_STATE` を混同してはならない。

---

## 8. 状態モデル対応例

### 例1

```text
metadata.lifecycle_state = REGISTERING
GitHub runner = present
Windows Service = absent
```

結果:

```text
CALLER_RUNNER_SNAPSHOT_STATE=PARTIAL
CALLER_RUNNER_LIFECYCLE_STATE=REGISTERING
RECOVERY_DECISION=RESUME_SAFE
```

### 例2

```text
metadata = absent
GitHub runner = present
Windows Service = present
actual state = expected stateと完全一致
```

結果:

```text
CALLER_RUNNER_SNAPSHOT_STATE=PARTIAL
CALLER_RUNNER_LIFECYCLE_STATE=ABSENT
RECOVERY_DECISION=RECOVER_WITH_APPROVAL
```

### 例3

```text
metadata.repository_id != actual repository_id
```

結果:

```text
CALLER_RUNNER_SNAPSHOT_STATE=CONFLICT
RECOVERY_DECISION=MANUAL_INTERVENTION_REQUIRED
```

### 例4

```text
metadata.lifecycle_state = ACTIVE
GitHub runner / Service / labels / identity / path 全一致
```

結果:

```text
CALLER_RUNNER_SNAPSHOT_STATE=CONSISTENT
CALLER_RUNNER_LIFECYCLE_STATE=ACTIVE
RECOVERY_DECISION=RETRY_SAFE
```

この場合 operation は no-op verification とする。

`RECOVERABLE`、`RECOVERABLE_EXISTING` 等の曖昧な enum は使用しない。

---

## 9. Inspect

`Inspect` は read-only operation とする。

最低限以下を actual state から取得する。

```text
repository identity
local runner presence
GitHub runner registration
runner labels
duplicate registration
runner directory
runtime metadata
exact Windows Service name
service PathName
service identity
service state
runner/service association
current local execution
current execution repository_id
```

`Inspect` は最低限以下を返す。

```text
HOST_STATE
CALLER_RUNNER_SNAPSHOT_STATE
CALLER_RUNNER_LIFECYCLE_STATE
RECOVERY_DECISION
```

Mutation は行わない。

---

## 10. Runner Identity

Repository-scoped runner の primary identity は immutable repository ID とする。

Canonical runner directory:

```text
C:\codex-runners\repo-<repository_id>
```

例:

```text
C:\codex-runners\repo-1350660842
```

Canonical runner name:

```text
codex-repo-<repository_id>
```

Repository name は display / read-back verification に利用してよいが、primary key にしない。

---

## 11. Runtime Metadata

Automation-owned runtime metadata を以下へ保持する。

```text
C:\ProgramData\CodexAutomation\runners\
```

Active:

```text
active\<repository_id>.json
```

Retired:

```text
retired\<repository_id>.json
```

Metadata に credential は保存しない。

主な項目:

```json
{
  "schema": 1,
  "repository_id": "1350660842",
  "repository_full_name": "owner/repository",
  "runner_directory": "C:\\codex-runners\\repo-1350660842",
  "runner_name": "codex-repo-1350660842",
  "service_name": "<exact-service-name-or-null>",
  "lifecycle_state": "REGISTERING",
  "state_entered_at": "2026-09-15T02:34:56Z"
}
```

`state_entered_at` は lifecycle state が変化するたびに更新する。

これは diagnostic / audit 用であり、authority ではない。

一定時間経過したことだけを理由に automatic rollback や mutation を行ってはならない。

Metadata update は atomic write とする。

---

## 12. Lifecycle State Machine

### Onboard states

```text
ABSENT
  ↓
REGISTERING
  ↓
REGISTERED
  ↓
SERVICE_INSTALLING
  ↓
SERVICE_INSTALLED
  ↓
ACTIVE
```

### Offboard states

```text
ACTIVE
  ↓
RETIRING
  ↓
DISPATCH_DISABLED
  ↓
SERVICE_STOPPED
  ↓
RUNNER_REMOVED
  ↓
RETIRED
```

各 state transition は明示的な precondition と postcondition を持つ。

---

## 13. Idempotency / Resume Policy

Onboard / Offboard は可能な限り冪等かつ再実行可能とする。

Operation 再実行時は:

```text
desired state
+
runtime metadata
+
actual state
```

を read-back し、既に安全に完了している step は skip する。

例:

```text
metadata = REGISTERED
GitHub runner = present
Windows Service = absent
```

の場合:

```text
CALLER_RUNNER_SNAPSHOT_STATE=PARTIAL
RECOVERY_DECISION=RESUME_SAFE
```

として Service installation から再開する。

既に完了済みの GitHub registration を再実行しない。

---

## 14. Crash Consistency

Runtime metadata は completed state の記録だけではなく、intent / intermediate state も保持する。

Runner registration:

```text
REGISTERING metadata write
        ↓
GitHub registration
        ↓
actual read-back
        ↓
REGISTERED metadata update
```

Service install:

```text
SERVICE_INSTALLING metadata update
        ↓
Windows Service install
        ↓
exact service identity read-back
        ↓
SERVICE_INSTALLED metadata update
```

Process crash 後も lifecycle state と actual state の組み合わせから再開可否を判断する。

---

## 15. Metadata Missing Recovery

Actual state が存在するが metadata が欠損している場合、自動推測して継続しない。

以下がすべて完全一致する場合のみ:

```text
repository ID
canonical runner directory
canonical runner name
GitHub runner registration
expected labels
exact service state
NETWORK SERVICE identity
PathName
repository association
```

結果を:

```text
CALLER_RUNNER_SNAPSHOT_STATE=PARTIAL
RECOVERY_DECISION=RECOVER_WITH_APPROVAL
```

とする。

Plan に以下を明示する。

```text
RECONSTRUCT_RUNTIME_METADATA=true
```

Single approval gate 後に metadata を actual state から再構築する。

一致条件が1つでも欠ける場合:

```text
CALLER_RUNNER_SNAPSHOT_STATE=CONFLICT
RECOVERY_DECISION=MANUAL_INTERVENTION_REQUIRED
```

とする。

---

## 16. Windows Service Identity

PathName が一致する Service を検索して採用してはならない。

Exact service name を runtime metadata と actual Windows Service read-back の両方から検証する。

検証対象:

```text
exact service name
PathName
service identity
service state
runner directory
repository ID association
```

未知の Service 名を PathName 一致だけで採用しない。

---

## 17. Onboard Flow

概念順序:

```text
full read-only grounding
        ↓
snapshot / lifecycle classification
        ↓
recovery decision
        ↓
consolidated plan
        ↓
single operator approval
        ↓
Secret / IAM preparation
        ↓
runtime metadata = REGISTERING
        ↓
runner registration
        ↓
actual runner read-back
        ↓
runtime metadata = REGISTERED
        ↓
Service installation
        ↓
actual Service read-back
        ↓
runtime metadata = SERVICE_INSTALLED
        ↓
runner/service verification
        ↓
runtime metadata = ACTIVE
        ↓
caller workflow synchronization
        ↓
full verification
```

Workflow synchronization を runner/service activation より後に置く。

途中失敗時に新規 job dispatch が始まることを避ける。

---

## 18. Onboard Recovery

Onboard 中断後の再実行は lifecycle state と actual state に応じて再開する。

### REGISTERING + GitHub registrationなし

```text
CALLER_RUNNER_SNAPSHOT_STATE=PARTIAL
RECOVERY_DECISION=RESUME_SAFE
→ registrationを再試行
```

### REGISTERING + GitHub registrationあり

```text
actual read-back一致
→ REGISTEREDへ進める
```

### REGISTERED + Serviceなし

```text
→ Service installから再開
```

### SERVICE_INSTALLING + exact Serviceあり

```text
actual state完全一致
→ SERVICE_INSTALLEDへ進める
```

### actual state と lifecycle metadata が矛盾

```text
CALLER_RUNNER_SNAPSHOT_STATE=CONFLICT
RECOVERY_DECISION=MANUAL_INTERVENTION_REQUIRED
```

自動 destructive rollback は行わない。

---

## 19. Offboard Flow

概念順序:

```text
full read-only grounding
        ↓
snapshot / lifecycle classification
        ↓
recovery decision
        ↓
consolidated plan
        ↓
single operator approval
        ↓
runtime metadata = RETIRING
        ↓
caller workflow retire/remove
        ↓
new dispatch disabled確認
        ↓
runtime metadata = DISPATCH_DISABLED
        ↓
target caller quiescence確認
        ↓
Service stop
        ↓
runtime metadata = SERVICE_STOPPED
        ↓
runner unregister
        ↓
actual absence read-back
        ↓
runtime metadata = RUNNER_REMOVED
        ↓
Secret exact version disable
        ↓
IAM cleanup
        ↓
retired caller metadata確定
        ↓
active runtime metadataをretiredへ移動
        ↓
runtime metadata = RETIRED
        ↓
full verification
```

---

## 20. Quiescence Policy

Offboard は実行中 job を暗黙に kill しない。

Quiescence は shared host 全体ではなく、**offboard対象 repository_id に所有される execution** を対象に判断する。

既存 Self-hosted Execution の `current-run.json` は `repository_id` を明示フィールドとして保持していることを前提とする。

Execution ID 文字列の parsing から repository ID を逆算してはならない。

確認対象:

```text
対象repository_idのqueued/running jobなし
対象repository_idのactive executionなし
current-run.json.repository_id != 対象repository_id
対象repository_idに属するresidual execution stateなし
```

Global Mutex が held であっても、別 caller の execution が保持している場合は対象 caller の offboard をブロックしない。

例:

```text
caller Aをoffboard中

current-run.json.repository_id = caller B
Global Mutex held
→ caller Aのoffboardを不要にblockしない

current-run.json.repository_id = caller A
→ quiescence待ち
```

Mutex が busy だが `current-run.json` が存在しない、壊れている、または ownership を一意に特定できない場合は、race / corruption を推測で処理せず bounded wait 後に fail closed とする。

Timeout policy:

```text
host.execution.quiescence_timeout_seconds
```

未指定時:

```text
default = 600 seconds
```

Timeout 時:

```text
do not kill job
do not stop service
do not unregister runner

RESULT=STOP
REASON=QUIESCENCE_TIMEOUT
RECOVERY_DECISION=RETRY_SAFE
```

強制停止は通常 Offboard の自動処理には含めない。

別の明示的 operator action とする。

---

## 21. Offboard Recovery

Offboard も lifecycle state から再開可能とする。

### RETIRING + workflow still active

```text
→ workflow retirementから再開
```

### DISPATCH_DISABLED + target caller active jobあり

```text
→ quiescence待ちから再開
```

### SERVICE_STOPPED + runner still registered

```text
→ runner unregisterから再開
```

### RUNNER_REMOVED + Secret enabled

```text
→ Secret disableから再開
```

### RETIRED

```text
→ no-op verification
```

Actual state と lifecycle metadata が矛盾する場合は:

```text
CALLER_RUNNER_SNAPSHOT_STATE=CONFLICT
RECOVERY_DECISION=MANUAL_INTERVENTION_REQUIRED
```

とする。

---

## 22. Runner Metadata Retirement

Offboard 完了時に active metadata を削除しない。

以下へ移動する。

```text
active\<repository_id>.json
        ↓
retired\<repository_id>.json
```

Retired metadata は local recovery evidence として保持する。

正式な Re-onboarding authority にはしない。

Retired metadata に credential を保存しない。

`state_entered_at` は `RETIRED` 遷移時に更新する。

---

## 23. Re-onboarding Authority

正式な Re-onboarding authority は private desired state の `retired-callers` metadata のみとする。

Required authority:

```text
repository.id
secret.id
last_authoritative_secret_version
```

以下を production authority としない。

```text
environment variable
CLI override
latest Secret version
max version
disabled version guess
local retired runtime metadataのみ
```

Restore candidate 条件:

```text
retired desired state read
        ↓
actual immutable repository ID
        ↓
repository ID一致
        ↓
Secret ID一致
        ↓
exact numeric version exists
        ↓
exact version == DISABLED
        ↓
enabled count == 0
        ↓
authentication validity
        ↓
RESTORE_CANDIDATE
```

Local retired runner metadata は cross-check evidence としてのみ利用する。

---

## 24. GitHub Administrative Credential Boundary

Runner registration / unregistration などの GitHub administrative operation は Bootstrap Operator identity を使用する。

Codex runtime 自身には GitHub write credential を渡さない。

Bootstrap Operator process は interactive `gh` authentication を持つ。

Temporary runner registration/removal credential は:

```text
必要時だけ取得
        ↓
そのoperationだけに渡す
        ↓
operation終了後破棄
```

Git、runtime metadata、log、desired stateへ保存しない。

受け渡し方式は process argument よりも stdin または同等の ephemeral protected mechanism を優先する。

Process list 等から credential が露出する方式は避ける。

---

## 25. Secret Lifecycle

Offboard 前:

```text
actual Secret Manager query SUCCESS
exactly one enabled version
exact numeric authoritative version confirmed
```

Operation plan に exact version を固定する。

Disable 後:

```text
operation SUCCESS
actual query SUCCESS
enabled count == 0
same numeric version == DISABLED
```

結果分類:

```text
SUCCESS_WITH_RESULTS
SUCCESS_EMPTY
ERROR
```

`ERROR` を `SUCCESS_EMPTY` と解釈してはならない。

---

## 26. Test Architecture

Production と Test の差は主として state provider と mutation provider に限定する。

### Production

```text
actual GitHub
actual Windows Service
actual filesystem/runtime
actual Google Cloud
```

### Test

明示 CLI:

```text
-TestMode
-FixtureRoot <temporary isolated directory>
```

Test Mode は environment variable では有効化しない。

Test fixture は arbitrary command を注入しない。

Fixture state を同じ classifier / state machine へ入力する。

---

## 27. Test Mode Boundary

Test Mode の成立条件:

```text
explicit -TestMode
temporary FixtureRoot
known fixture schema
FixtureRootがapproved temporary location
production resourceでない
```

Test Mode では actual external mutation を禁止する。

以下を呼んではならない。

```text
real runner registration
real runner unregistration
real Windows Service mutation
real Secret mutation
real IAM mutation
real caller workflow mutation
```

Production invocation で Test Mode 関連 flag / fixture injection が検出された場合は STOP。

Environment variable の存在による Test Mode 自動判定は禁止する。

---

## 28. Fixture Timeout Policy

Test timeout の第一解決策を timeout 延長にしない。

以下を排除する。

```text
mock subprocess → production fallback
stdin wait
recursive invocation
retry loop
unexpected lock wait
actual gh invocation
actual gcloud invocation
arbitrary adapter subprocess
```

Fake command executionではなく、fixture stateを production と同じ state machine / validation logicへ投入する方式を基本とする。

---

## 29. Workflow Synchronization Contract

Caller workflow synchronization は既存 contract を利用する。

現在の canonical classification は:

```text
ABSENT
EXACT_TARGET
MANAGED_OLD
DIVERGED
```

とする。

意味:

```text
ABSENT
→ workflowなし

EXACT_TARGET
→ canonical targetと完全一致

MANAGED_OLD
→ approved known-old canonical workflowと完全一致

DIVERGED
→ 上記いずれにも該当しない
```

`DIVERGED` は fail closed とする。

`MANAGED_OLD` は explicit review / approval を経て canonical target へ full replacement し、post-sync exact equality を確認する。

Host Orchestration はこの contract を再設計せず利用する。

---

## 30. WIF Workflow SHA Rotation Contract

Reusable workflow SHA の trust rollout は既存の workflow SHA rotation contract を利用する。

Operation:

```text
initialize
stage
finalize
```

Rollout conceptual order:

```text
new automation SHA available
        ↓
stage
old SHA + new SHA を許可
        ↓
caller workflow sync
        ↓
E2E verification
        ↓
finalize
old SHAを明示確認後に除外
```

Host Orchestration は WIF trust model 自体を再設計しない。

---

## 31. Verified External Contracts

v0.4 では実装着手前の確認として、以下を前提契約として確定する。

### Workflow Sync

```text
ABSENT / EXACT_TARGET / MANAGED_OLD / DIVERGED
```

の分類および `MANAGED_OLD → target` の explicit sync path が存在する。

### WIF Rotation

```text
initialize / stage / finalize
```

の SHA rotation path が存在する。

### Local Execution Ownership

`current-run.json` は少なくとも以下を保持する。

```text
execution_id
repository_id
github_run_id
github_run_attempt
```

Quiescence は `current-run.json.repository_id` を直接利用する。

Execution ID 文字列の parsing を authority にしない。

---

## 32. Workflow Synchronization Scope

本設計では以下をスコープ外とする。

```text
MANAGED_OLD policyそのものの再設計
WIF trust modelの再設計
production workflow intentional upgrade policyの再設計
```

Host Orchestration は既存 contract を利用するのみとする。

---

## 33. Fail-Closed Conditions

以下は自動 repair せず STOP する。

```text
repository ID mismatch
duplicate runner
unexpected labels
ambiguous GitHub runner registration
unknown Service name
Service PathName mismatch
Service identity mismatch
runner/service association mismatch
metadataとactual stateの矛盾
unsupported metadata schema
unknown lifecycle state
multiple enabled Secret versions
external read-back error
unexpected workflow divergence
production Test Mode detection
target caller quiescence timeout
execution ownership ambiguity
credential source ambiguity
```

STOP 時には最低限以下を出力する。

```text
reason
HOST_STATE
CALLER_RUNNER_SNAPSHOT_STATE
CALLER_RUNNER_LIFECYCLE_STATE
RECOVERY_DECISION
observed state
expected state
allowed recovery action
```

単なる `INCONSISTENT` のみでは終わらせない。

---

## 34. Recovery Decision

### RETRY_SAFE

Mutation が開始されていない、または安全に同一stepを再試行可能。

### RESUME_SAFE

Lifecycle metadata と actual state が整合し、次のstepから安全に再開可能。

### RECOVER_WITH_APPROVAL

Actual state が一意で、metadata reconstruction 等の bounded recovery により復旧可能。

Plan + approval が必要。

### MANUAL_INTERVENTION_REQUIRED

Identity ambiguity、unknown Service、duplicate state、ownership ambiguity 等。

自動 mutation 禁止。

---

## 35. Planned File Changes

主な変更候補:

```text
scripts/onboarding/onboard-caller.sh
scripts/onboarding/offboard-caller.sh
scripts/lib/phase12b-config.sh
scripts/host/phase12b-host.psm1
scripts/host/verify-host.ps1
scripts/onboarding/test-phase12b-config.sh
scripts/host/test-phase12b-host.ps1
```

新規追加候補:

```text
scripts/host/caller-runner.ps1
```

必要に応じて runtime metadata helper を既存 host module 内へ追加する。

新しい module を不必要に増やさない。

---

## 36. runner-adapter.ps1 の扱い

Generic arbitrary adapter pattern は本設計では採用しない。

既存または未実装の `runner-adapter.ps1` が:

```text
arbitrary command injection
operator-controlled production adapter
environment-controlled mutation
```

を目的としている場合は採用しない。

一方、固定された production provider abstraction として利用可能な設計であれば、`phase12b-host.psm1` の内部 implementation detail として再評価してよい。

最終的な logic owner は `phase12b-host.psm1` とする。

---

## 37. Security Invariants

本設計は以下を維持する。

```text
Codex runtimeにGitHub write credentialを渡さない
credentialsをGitへ保存しない
Secret payloadを不用意に読まない
immutable repository IDをprimary identityとする
one approval gate
actual read-back
fail closed
resume/recoveryもactual stateから判断
NETWORK SERVICE policy
repository-scoped runners
shared Execution Area
Global Mutex serialization
```

Global Mutex は共有資源であるが、quiescence 判定では対象 caller の execution ownership を必ず識別する。

---

## 38. Idempotency Invariants

Onboard / Offboard / Verify は以下を満たす。

```text
completed stepの再実行でduplicate resourceを作らない
safe intermediate stateからresumeできる
completed operationの再実行はverification/no-opになる
ambiguous stateは自動repairしない
他callerの実行状態を対象callerのlifecycle stateと混同しない
```

---

## 39. Audit / Result Contract

各 operation は最低限以下を返す。

```text
ACTION
RESULT
REPOSITORY_ID
HOST_STATE
CALLER_RUNNER_SNAPSHOT_STATE
CALLER_RUNNER_LIFECYCLE_STATE_BEFORE
CALLER_RUNNER_LIFECYCLE_STATE_AFTER
RECOVERY_DECISION
STATE_ENTERED_AT
MUTATIONS_PERFORMED
POSTCONDITION
NEXT_ACTION
```

Credential や Secret payload は出力しない。

---

## 40. Implementation Order

実装は以下の順で進める。

```text
1. state terminology / enum namespace
2. metadata lifecycle schema + state_entered_at
3. Snapshot Inspect / classifier
4. Recovery Decision mapping
5. caller-runner.ps1 thin CLI
6. Onboard resume state machine
7. Offboard resume state machine
8. repository_id-aware quiescence
9. configurable quiescence timeout
10. Secret lifecycle integration
11. Re-onboard cross-check
12. Test provider / fixture architecture
13. timeout regression
14. full Independent Tester
15. Independent Reviewer
```

State machine、recovery、execution ownership 判定を先に完成させてから mutation path を接続する。

---

## 41. Test Requirements

### State namespace

```text
HOST_STATEとCALLER_RUNNER_SNAPSHOT_STATEを混同しない
旧RECOVERABLE系enumが残っていない
Snapshot / Lifecycle / Recovery mappingが一意
```

### Onboard

```text
ABSENT → ACTIVE
REGISTERINGからresume
REGISTEREDからresume
SERVICE_INSTALLINGからresume
completed ACTIVE再実行 → no-op verification
metadataとactual不一致 → CONFLICT / STOP
```

### Metadata recovery

```text
metadata missing + exact actual一致
→ PARTIAL + RECOVER_WITH_APPROVAL

metadata missing + ambiguity
→ CONFLICT + MANUAL_INTERVENTION_REQUIRED
```

### Offboard

```text
ACTIVE → RETIRED
RETIRINGからresume
DISPATCH_DISABLEDからresume
SERVICE_STOPPEDからresume
RUNNER_REMOVEDからresume
RETIRED再実行 → no-op verification
```

### Quiescence

```text
対象caller実行なし
→ PASS

current-run.repository_id = 対象caller
→ WAIT

current-run.repository_id = 別caller
→ 対象callerのoffboardを不要にblockしない

Mutex busy + current-run ownership不明
→ bounded wait
→ unresolvedならSTOP

configured timeout
→ STOP
→ jobをkillしない
```

### state_entered_at

```text
state遷移時に更新
restart後も保持
timestampだけを理由にautomatic mutationしない
```

### Workflow sync

```text
EXACT_TARGET → NO_CHANGE
MANAGED_OLD → explicit approved sync
DIVERGED → STOP
ABSENT → onboarding candidate
post-sync exact equality
```

### Test boundary

```text
-TestMode + valid fixture → PASS
-TestMode without FixtureRoot → STOP
production fixture injection → STOP
environment variable test activation → rejected
```

### Secret

```text
ERROR != SUCCESS_EMPTY
multiple enabled → STOP
exact version disable → PASS
post-disable enabled version exists → STOP
```

### Security

```text
credential not persisted
repository ID primary
wrong Service identity → STOP
duplicate runner → STOP
DIVERGED workflow → STOP
other caller executionを誤ってtarget callerとして扱わない
```

---

## 42. Out of Scope

本設計では以下を扱わない。

```text
Phase 12B全体architectureの再設計
WIF trust model変更
trusted publication model変更
full OS isolation between callers
separate Windows identity per caller
VM / physical host isolation
workflow upgrade policy再設計
forced termination of running jobs
Global Mutexそのものの廃止またはcaller別Mutex化
```

---

## 43. Open Decisions

v0.4 時点で実装開始を妨げる設計上の未決事項はなしとする。

以下は implementation verification item として扱い、architecture decision へ戻さない。

```text
既存未commit差分との整合
current-run read-only ownership判定の実装位置
quiescence timeout configuration parsing
atomic runtime metadata更新方法
runner registration credentialの具体的ephemeral handoff
runner-adapter.ps1の採否
```

これらの実装により security boundary や top-level architecture を変更する必要が生じた場合のみ、設計判断へ戻す。

---

## 44. v0.3 → v0.4 変更点

Final review と実装突き合わせを受け、以下を変更・確定した。

```text
Statusを Reviewed / Implementation Ready へ変更

host-level stateを
HOST_STATE
として明示

caller runnerの状態を
CALLER_RUNNER_SNAPSHOT_STATE
CALLER_RUNNER_LIFECYCLE_STATE
RECOVERY_DECISION
としてnamespace分離

host.execution.quiescence_timeout_secondsを追加
default 600秒
host policyとして変更可能にした

Global Mutex ownership判定で
execution_id文字列をparseせず
current-run.json.repository_idを直接利用すると明記

別callerがGlobal Mutexを保持している場合は
対象caller offboardを不要にblockしないことを確定

Mutex busyかつexecution ownership不明時は
bounded wait後にfail closedと明記

workflow sync contractの実在を確認
ABSENT / EXACT_TARGET / MANAGED_OLD / DIVERGED
を正式前提として明記

MANAGED_OLDのexplicit sync pathと
post-sync equality確認を前提contractとして明記

WIF workflow SHA rotationの
initialize / stage / finalize
contractを確認済み前提として明記

current-run.jsonに
repository_idが明示保存されることを
verified external contractとして追加

Open Decisionsを
NONE相当とし、
残項目をimplementation verification itemへ変更
```

---

## 45. 非技術者向け要約

この仕組みでは、caller の追加・削除処理が途中で止まっても、「今どこまで終わっているのか」と「実際のPC・GitHub・Google Cloudの状態」を照らし合わせ、安全なところから続行できるようにする。

状態は用途ごとに分ける。

```text
PC全体の状態
        ↓
HOST_STATE

caller runnerの実物の状態
        ↓
CALLER_RUNNER_SNAPSHOT_STATE

caller処理がどこまで進んでいたか
        ↓
CALLER_RUNNER_LIFECYCLE_STATE

次に何をしてよいか
        ↓
RECOVERY_DECISION
```

安全に続けられるなら続きから再開する。

安全に復元できるが変更が必要なら、planを出して承認後に復元する。

何が正しいか一意に判断できない場合は、自動で触らず STOP する。

また、複数callerが同じWindows PCとGlobal Mutexを共有していても、別callerが実行中というだけでoffboard対象callerを不必要に止めない。

```text
current-run.json.repository_id
```

を直接確認し、その実行がどのcallerのものかを判定する。

Caller workflowについても、

```text
EXACT_TARGET
MANAGED_OLD
DIVERGED
```

を区別し、既知の旧管理版だけを明示承認のうえで更新する。

この v0.4 を Phase 12B Host Orchestration の **Implementation Ready 設計** とし、以後は Codex による bounded implementation、Independent Tester、Independent Reviewer の順で実装検証へ進む。
