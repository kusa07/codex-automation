# Phase 10 Execution Plan

## 1. 目的

この文書は、`ROADMAP.md` の Phase 10 を実際にどの順序・作業指示単位で進めるかを定義する。

Phase 10 の目的とcompletion criteriaは `ROADMAP.md`、Self-hosted Executionのarchitecture / security boundaryは `SELF_HOSTED_EXECUTION.md` を正とする。

この文書は、それらを変更するものではなく、実装・検証をCodexへ依頼する際のexecution planとgrounding ruleを固定するための運用上の正本である。

Phase 10中は、ChatGPTとCodexはこの文書に記録された作業単位、順序、grounding gate、STOP条件を前提に進行する。

---

## 2. 現在地

現在のauthoritative roadmap stateは以下である。

```text
Phase 9
  Complete

Phase 10
  Next
```

Phase 10のSelf-hosted Execution architectureは承認済みであり、関連documentationも整合済みである。

GitHub-hosted Ubuntuでのworkspace-write / bwrap investigationはclosedであり、自動的に再開しない。

`CA-P10-028` のManaged Execution Area実装・negative-path validationは完了し、`CA-P10-028.5` でauthoritative `main`へ着地済みである。

着地commit:

```text
db588b22d97bc04efc9664fce0872d3a6e969d74
Implement managed self-hosted execution area
```

着地済み成果物:

```text
scripts/self-hosted/manage-execution-area.sh
scripts/self-hosted/managed-execution-area.ps1
scripts/self-hosted/test-managed-execution-area.sh
```

`CA-P10-029_001` ではlocal execution controlをisolated worktree内で試作・検証したが、Independent Reviewerがcross-session Mutex / abandoned ownership / post-cleanup validationのblocking issueを検出したため、`STOP_AND_REPORT` とした。候補実装はauthoritative `main`へ着地していない。

User / ChatGPT判断として、`CA-P10-029_001_002` で以下を承認した。

- GitHub Actions runner本体はManaged Execution Areaの外部に置き、`CA-P10-028`のmanaged-root schemaは変更しない
- local lockはsession-localな `Local\` named Mutexではなく、cross-sessionで共有される `Global\` named Mutexを使用する
- Mutex名はexecution-area identityから安定して導出する
- Global Mutexには明示的DACLを設定し、normal executionで必要なrunner Windows identityへ必要最小限のaccessを与える
- 専用runner accountはPhase 10必須とはしないが、runnerの実行identityは明示的に確定・検証する
- abandoned Mutex検出時はownership取得済みとして扱い、lockを保持したままresidual stateを検査し、payloadを実行せず、finally相当でreleaseしてfail closedする
- command success/failureにかかわらず、自分が作成した`current-run.json`のcleanup後にpost-run residual validation / idle preflightを行い、その後にMutexをreleaseする

`CA-P10-029_002` の最初の実行は、当時の本計画がlocal execution controlの修正・再検証だけをscopeとしていた一方、指示文がrunner registration / GitHub inert dispatch / availabilityまで要求していたため、Grounding Gateでscope mismatchを検出して `STOP_AND_REPORT` した。host / GitHub resource / repositoryへのwriteは行っていない。

その後User / ChatGPTは、利用枠が十分あることと既存のarchitecture/security判断が確定していることを踏まえ、`CA-P10-029_002` を **CA-P10-029の残り全体を完了させる1つの実作業指示** として扱うことを明示承認した。

`CA-P10-029_002_002` はこの承認を本計画へ同期するdocumentation-only管理番号である。

次の実作業は:

```text
CA-P10-029_002
CA-P10-029 remaining implementation + integration + validation

Stage A: local execution control completion
Stage B: self-hosted runner bootstrap / registration / binding
Stage C: GitHub -> Windows credential-free inert dispatch
Stage D: availability / negative integration validation
```

である。

各Stageの間にcheckpointを置き、前Stageがblockingなら後Stageへ進まない。approved design内の局所bugはbounded fix / retestしてよいが、新しいarchitecture / security boundaryが必要になった場合は `STOP_AND_REPORT` する。

`CA-P10-029_003` は現時点では作成しない。`CA-P10-029_002` が全completion criteriaを満たした場合は `CA-P10-029` をCompleteとし、次の実作業は `CA-P10-030` とする。

---

## 3. Phase 10 全体の作業塊

Phase 10の残作業は、以下の4つの作業塊として扱う。

```text
作業塊 1: Self-hosted基盤
    B + C + D

作業塊 2: 既存資産をSelf-hostedへ載せる
    E + F + G

作業塊 3: Write + Publication
    H + I

作業塊 4: End-to-End
    J
```

B〜Jは検証上のlogical stepであり、Codexへの指示文は必ずしも1 step = 1指示とはしない。

同じfailure domain、同じ環境、同じgrounding contextで連続して実装・検証した方が安全かつ効率的なものは1つの管理番号へまとめる。

---

## 4. Codex作業指示単位

Phase 10は、現時点では以下の6つのcore work unitで進める。

| 管理番号 | 対応step | 作業塊 | 目的 | 想定重さ | 状態 |
|---|---|---|---|---|---|
| `CA-P10-028` | B | 1 | Managed Execution Area実装 + negative-path検証 | 中〜重 | Complete / landed |
| `CA-P10-029` | C + D | 1 | Self-hosted runner / Git Bash / Mutex / availability / inert dispatch | 重 | In progress |
| `CA-P10-030` | E | 2 | Workspace lifecycle + 既存bashのWindows/Git Bash適応 | 中〜重 | Planned |
| `CA-P10-031` | F + G | 2 | WIF / Secret / isolated Codex runtime + Local Codex read-only | 重 | Planned |
| `CA-P10-032` | H + I | 3 | workspace-write + existing trusted publication再接続 | 重 | Planned |
| `CA-P10-033` | J | 4 | Issue → Local Codex → Draft PR E2E validation | 中〜重 | Planned |

計画上の6件を機械的に守ること自体は目的ではない。

read-only groundingの結果、1件のscopeが安全に実施できないほど大きい、またはfailure domainが予想以上に分離している場合は、その場で勝手に追加taskへ分割せず、`STOP_AND_REPORT` としてChatGPT / Userへ戻す。

逆に、後続taskの内容を前倒しで実装してはならない。明示的な承認なく管理番号のscopeを拡大しない。

### 4.1 補助・分割管理番号

Core work unitの実装結果を安全に着地させる、execution planをactual stateへ同期する、または利用枠 / failure domainに応じてcore work unitを安全に分割するために補助管理番号を使用してよい。

現時点の補助・分割管理番号:

| 管理番号 | 目的 | 状態 |
|---|---|---|
| `CA-P10-028.5` | `CA-P10-028`の検証済み3ファイルをauthoritative `main`へ着地 | Complete |
| `CA-P10-028.5_002` | `CA-P10-028` / `CA-P10-028.5`実績を本計画へ同期 | Complete |
| `CA-P10-029_001` | local execution controlのgrounding / 試作 / review | STOP_AND_REPORT / not landed |
| `CA-P10-029_001_002` | `029_001`のblocking findingを受けたrunner placement / Global Mutex / ACL / cleanup設計決定と計画同期 | Complete |
| `CA-P10-029_002` | CA-P10-029の残り全体: local execution control完成 + runner登録/binding + inert dispatch + availability/integration validation | Next (re-run after scope sync) |
| `CA-P10-029_002_002` | `029_002`をStage A〜Dのremaining work全体へ拡張する承認を本計画へ同期 | Complete |

補助・分割管理番号はROADMAP上のphaseやB〜Jのlogical validation stepを増やさない。

---

## 5. Git Bash 方針

Phase 10のWindows Self-hosted Executionでは、既存のbash資産を最大限再利用する。

基本方針:

```text
GitHub Actions self-hosted runner
    ↓
Git Bash
    ├─ existing bash workflow logic
    ├─ git / gh
    ├─ node / npm
    ├─ gcloud
    └─ Codex CLI

Windows固有処理のみ
    ↓
PowerShell / .NET helper
```

PowerShellへworkflow全体を全面移植することはPhase 10の初期方針ではない。

Windows固有処理の例:

- Windows named Mutex
- NTFS / ACL関連処理
- Windows path / reparse point検証
- 必要なatomic replace処理
- Windows Service / runner bootstrapに必要な処理

`chmod` 等のPOSIX permission操作がGit Bash上で成功しても、それだけをWindows上のsecurity boundaryとみなしてはならない。

既存bashの実際の互換性は `CA-P10-030` でgrounding / validationする。

---

## 6. Grounding Gate

各 `CA-P10-*` 作業は、writeを始める前にParent agentがread-only groundingを行う。

目的は、ChatGPTが作成した指示文の想定と、実際のrepository / local machine / workflow / previous resultとの差を実装前に検出することである。

### 6.1 判定

Grounding結果は、以下のいずれかへ分類する。

#### PROCEED

計画上の想定とactual stateが一致しており、承認済みscopeのまま安全に実装できる。

→ 指示された実装・検証へ進む。

#### ADJUST_WITHIN_SCOPE

実装詳細に小さな差異があるが、architecture、security boundary、roadmap、caller contract、task scopeを変えずに適応できる。

例:

- 実際のtool pathが想定と少し異なる
- 既存helperの配置が想定と異なる
- Git Bash上のpath表現へ小さな適応が必要
- docsで想定したdirectory名より既存の適切な共通utilityが存在する

→ actual stateへ合わせて実装してよい。ただし最終報告で差分と対応を明記する。

#### STOP_AND_REPORT

以下のような差異がある場合はwrite前、または安全な停止点で停止する。

- architecture変更が必要
- security boundaryを変更する必要がある
- roadmap structure / completion criteria変更が必要
- caller contractの変更が必要
- runner ownership / trust modelが計画と実際で矛盾する
- credential handlingの新しい保存先・権限拡張が必要
- destructive recoveryが必要
- unknown / ambiguous managed execution areaが存在する
- current local worktreeの既存変更とtaskが安全に共存できない
- 想定したGit Bash再利用方針が成立せず、PowerShell全面移植等の大きなstrategy changeが必要
- closed済みGitHub-hosted bwrap investigationの再開が必要
- 計画されたtaskを別failure domainへ大きく拡張する必要がある

→ 勝手に新設計や長時間調査へ進まず、actual state、差分、選択肢を報告してUser / ChatGPT判断を待つ。

---

## 7. 共通 Grounding Checklist

各task開始時、Parentは必要範囲で以下をread-only確認する。

### 7.1 Repository state

- local repository identity
- current branch
- local HEAD
- remote default branch / remote HEAD
- ahead / behind
- tracked dirty files
- untracked files
- taskに関係する既存実装
- previous `CA-P10-*` で作成されたfiles / changes

既存のdirty stateがあっても、次を自動実行してはならない。

```text
reset
stash
clean
rebase
force push
```

既存変更を消したり隠したりせず、安全に共存できない場合はSTOPする。

### 7.2 Documentation

少なくともtaskに関連する以下を読む。

- `ROADMAP.md`
- `PHASE10_EXECUTION_PLAN.md`
- `SELF_HOSTED_EXECUTION.md`
- `AGENTS.md`
- `SECURITY.md`
- `OPERATIONS.md`
- `CONTRACT.md`
- 必要に応じて `ARCHITECTURE.md`, `GOOGLE_CLOUD.md`, `PROTOCOL.md`

remembered stateや過去chatよりcurrent repository documentationを優先する。

### 7.3 Local environment

そのtaskで必要な範囲でactual environmentを確認する。

例:

- Windows version / build
- Git Bash availability / version
- Git
- `gh`
- PowerShell
- Node / npm
- gcloud
- Codex CLI
- self-hosted runner state
- relevant filesystem/path behavior

Windows product nameの表示差だけでOS要件違反と断定しない。必要な場合はbuild/versionまで確認する。

未使用のtoolまで毎回網羅的に調査する必要はない。

### 7.4 Previous task result

前taskが存在する場合、以下を確認する。

- management ID
- actual changes
- validated behavior
- unresolved uncertainty
- temporary diagnostic codeの有無
- documented next task

前taskの「計画上成功するはず」ではなく、実際に検証済みの内容を次taskのinputとする。

---

## 8. Groundingから実装への流れ

各taskの基本フローは以下とする。

```text
Parent read-only grounding
    ↓
actual state と plan / prompt を照合
    ↓
PROCEED / ADJUST_WITHIN_SCOPE / STOP_AND_REPORT
    ↓
必要な場合のみsubagent routing
    ↓
implementation
    ↓
validation
    ↓
必要なら bounded fix / retest
    ↓
final review
    ↓
report
```

Subagentを使うこと自体を目的にしない。

Parentはgrounding後に、taskの実際の複雑性とriskに応じて必要なroleだけを使う。

重大なarchitecture / security / roadmap判断はsubagentやParentが独自決定せず、User / ChatGPTへ戻す。

---

## 9. Investigation / usage-budget guardrail

1つの大きな指示へまとめる理由は、毎回のdocs再読・repository grounding・環境確認の重複を減らすためである。

一方、1task内で無制限に問題を追跡してはならない。

基本:

```text
grounding
    ↓
implementation
    ↓
validation
    ↓
必要なら同一failure domain内のbounded fix / retest
    ↓
別failure domain / architecture issueへ拡大しそう
    ↓
STOP_AND_REPORT
```

`AGENTS.md` のinvestigation expansion guardrailを常に適用する。

Codex利用枠を消費してでも「何か答えを出す」ことより、既知の安全な状態で停止し、次の判断材料を残すことを優先する。

---

## 10. Task result contract

各 `CA-P10-*` の最終報告には少なくとも以下を含める。

1. management ID
2. groundingで確認したactual state
3. plan / prompt assumptionとの差
4. grounding decision
   - `PROCEED`
   - `ADJUST_WITHIN_SCOPE`
   - `STOP_AND_REPORT`
5. agent routingを実際にどうしたか
6. files changed
7. implementation summary
8. validation performed
9. validation results
10. failures / bounded fixes
11. remaining uncertainty
12. architecture / security / roadmap decisionが必要か
13. current Phase 10 completion statusへの影響
14. next planned management ID
15. commit / push / PR等を実施した場合はそのidentity

次taskの指示文は、このactual resultをChatGPTが確認してから作成する。

```text
PHASE10_EXECUTION_PLAN.md
        +
previous CA-P10 actual result
        +
current repository / environment
        ↓
next Codex instruction
```

計画書の次task descriptionをそのまま無条件に再利用しない。

---

## 11. CA-P10-028 — Managed Execution Area

### Status

**Complete / fully landed**

Authoritative commit:

```text
db588b22d97bc04efc9664fce0872d3a6e969d74
```

Actual implementation:

- `scripts/self-hosted/manage-execution-area.sh`
- `scripts/self-hosted/managed-execution-area.ps1`
- `scripts/self-hosted/test-managed-execution-area.sh`

Actual validation included Git Bash entrypoint validation, PowerShell parser validation, ensure/preflight success paths, fail-closed negative paths, idempotency, stable marker identity, atomic marker creation, residue checks, unknown-root-entry rejection, and junction/reparse-point rejection.

Grounding found that the original local checkout was stale and dirty, so implementation was performed in a clean isolated clone without modifying the pre-existing dirty tree. Git for Windows Bash was explicitly distinguished from Windows/WSL `bash.exe`.

### Goal

Managed Execution Areaを安全に作成・識別・検証できるようにし、正常系と主要なnegative pathを同一task内で検証する。

対応step: **B**

### Initial expected scope

- Git Bashを標準entrypointとするself-hosted management script
- Windows固有処理をPowerShell helperへ分離
- configurable execution root
- initial default root候補 `C:\codex-self-hosted`
- managed marker
- schema version
- execution-area identity
- atomic state write
- known required directory structure
- ensure
- preflight
- reparse point / path safetyの必要範囲の検証
- safe missing-directory completion
- fail-closed behavior
- test rootを使ったnegative-path validation

### Grounding重点

- repo内に既存self-hosted scripts / helpers / testsがあるか
- current local worktreeが安全に変更可能か
- Windows / Git Bash / PowerShell actual environment
- `SELF_HOSTED_EXECUTION.md` の現在のmarker / state / migration rule

### Main negative paths

最低限、実装に対応して以下を検証する。

- unmanaged existing root
- missing marker
- malformed marker
- unexpected `managed_by`
- unsupported schema
- execution root identity / path mismatchを採用した場合の不一致
- active / stale `current-run.json`
- sensitive temp residue
- Codex runtime credential residue
- atomic-write temp residue
- safe child directory不足
- ensure idempotency
- infrastructure reparse point等のpath escape

### STOP

runner registration、WIF、Secret、Local Codex、workspace-write、publicationへ進まない。

managed-area trust model自体を変更する必要がある場合はSTOPする。

### Initial recommended routing

- Model: Terra
- Reasoning: High
- Speed: Fast
- Parent grounding必須
- Implementer + Tester
- security-relevant final checkとしてIndependent Reviewerを使用

---

## 12. CA-P10-029 — Runner / Git Bash / Mutex / inert dispatch

### Status

**In progress**

`CA-P10-029_001` result:

```text
STOP_AND_REPORT
```

`029_001`ではisolated worktree内に以下の候補実装を作成したが、blocking reviewのためcommit/pushせず、authoritative `main`への変更は0件とした。

```text
scripts/self-hosted/local-execution.ps1
scripts/self-hosted/run-local-execution.sh
scripts/self-hosted/test-local-execution.sh
```

Blocking findings:

1. `Local\...` MutexはWindows session単位であり、将来runner serviceとinteractive processが別sessionになった場合にexecution-area全体の排他を保証できない
2. `AbandonedMutexException`発生時はownership取得済みだが、候補実装はそのownershipを確実にreleaseしていなかった
3. command failure時、`current-run.json`削除後のpost-run residual validation / idle preflightがhelper内部で保証されていなかった

`CA-P10-029_001_002` で承認した設計:

- runner本体はManaged Execution Area外のpersistent locationへ置く。例: `C:\codex-runner\`。これはexecution-area schemaの一部ではない
- `C:\codex-self-hosted\` の028 schemaは維持し、runner追加のためにschemaを変更しない
- local lockは `Global\` named Mutexとする
- Mutex名はexecution-area固有IDから安定して導出し、同じexecution areaをcross-sessionで同じlockへ収束させる
- Global Mutexはdefault broad ACLに依存せず明示的DACLを使う。normal executionで必要なrunner Windows identityに必要最小限のaccessを与える
- 専用runner accountはPhase 10の必須条件にはしない。ただしrunner service/accountを設定する際はactual Windows identity / SIDをgroundingして、Mutex DACLとlocal filesystem権限に整合させる
- abandoned Mutex検出時はownershipを保持したまま `ABANDONED_LOCK_DETECTED` を記録し、current-run / residual stateを検査する。payloadは実行しない。曖昧stateを正常化せず、finally相当でMutex ownershipをreleaseしてfail closedする
- normal command success / command failureの双方で、自分が作成した`current-run.json`をcleanupした後にpost-run residual validation / idle preflightを行い、その結果を確定してからMutexをreleaseする
- cleanup / residual validation failureはfull successとして扱わない

`CA-P10-029_002` first attempt result:

```text
STOP_AND_REPORT
```

理由は実装上のfailureではなく、本計画と指示文のscope mismatchである。当時の本計画はStage A相当だけを許可していた一方、指示文はrunner registration / GitHub inert dispatch / availabilityまで含めていた。Grounding Gateによりhost / GitHub resource mutationの前に停止し、repository / workflow / runner / GitHub Actionsへのwriteは0件だった。

`CA-P10-029_002_002` で承認・同期した現在のscopeでは、`CA-P10-029_002` は以下の4 Stageすべてを同一管理番号内で実施する。

```text
Stage A
Local execution control completion
- Global Mutex
- explicit DACL
- runner identity前提
- abandoned ownership/release
- Execution ID / current-run
- cleanup / post-run idle preflight
- local negative tests

        ↓ CHECKPOINT A

Stage B
Self-hosted runner bootstrap / registration / binding
- runnerはManaged Execution Area外
- official runner
- actual Windows identity / SID
- labels / eligibility
- trusted/private caller resource binding

        ↓ CHECKPOINT B

Stage C
GitHub -> Windows credential-free inert dispatch
- controlled trigger
- Git for Windows Bash
- managed-area preflight
- Global Mutex
- GitHub-derived Execution ID / current-run
- inert payload
- cleanup / idle preflight
- sanitized lifecycle evidence

        ↓ CHECKPOINT C

Stage D
Availability + negative integration validation
- online
- offline
- busy
- ineligible
- advisory/race boundary
- no long-lived credential expansion
```

各checkpointで前Stageのblocking issueが無いことを確認してから次へ進む。approved design内のlocal bugはbounded fix / retestしてよい。以下のような新しいarchitecture/security判断が必要になった場合は、そのStageで `STOP_AND_REPORT` する。

- public `codex-automation` repositoryへunsafeなself-hosted runner registrationが必要
- long-lived PAT / new broad GitHub credentialが必要
- runner identity / DACLを成立させるためにdedicated service account必須化やhost-wide ACL変更が必要
- caller contractやGitHub trust modelの変更が必要
- WIF / Secret / Codex executionへscopeを広げる必要
- alternative scheduler / orchestratorへ設計変更する必要

`CA-P10-029_003` は現時点では作成しない。

### Goal

GitHub ActionsからWindows self-hosted runnerへcredentialなしのjobを安全にdispatchし、local execution serializationとavailability gatingの基礎を成立させる。

対応step: **C + D**

### Initial expected scope

- runner bootstrap / registration approach
- runner labels / eligibility
- Git Bash execution availability
- required basic tool discovery
- managed execution areaとの接続
- Windows Global named Mutex
- explicit Mutex DACL
- abandoned mutex detection / ownership release
- Execution ID / current-run state integration
- post-run residual validation / idle preflight
- runner availability pre-check
- online / offline / busy / ineligible等の必要最小限のgate
- credential-free inert job
- sanitized lifecycle logging

### Grounding重点

- actual GitHub runner resource binding
- caller側と`codex-automation`側のresponsibility boundary
- Windows runner / Git Bash actual behavior
- `CA-P10-028` actual implementation
- `CA-P10-029_001` STOP resultと未着地candidate
- `CA-P10-029_001_002`で承認したGlobal Mutex / runner external placement / DACL / cleanup semantics
- `CA-P10-029_002` first attemptのscope-mismatch STOP result
- `CA-P10-029_002_002`で承認したStage A〜D統合scope
- GitHub-hosted precheckからself-hosted jobへのjob boundary
- current `CA-P10-028` managed root schemaではroot直下の許可entryが `state`, `workspaces`, `codex-home`, `temp`, `logs` とmarkerに限定され、unknown root entryはfail closedになること

Runner placementは以下で確定する:

```text
runner本体
    = Managed Execution Area外

Managed Execution Area
    = CA-P10-028 schemaを維持
```

runnerをmanaged root schemaへ追加しない。

### Completion concept

credentialやCodexを使わずに:

```text
GitHub Actions
    ↓
availability decision
    ↓
self-hosted runner
    ↓
managed-area preflight / Global local lock
    ↓
Git Bash inert command
    ↓
cleanup / post-run residual validation
    ↓
lock release
```

を通す。

Stage A〜Dがすべて成功し、必要なrepository / caller pin / runner resource stateが安全に着地・検証され、Independent Reviewerにblocking findingが無ければ `CA-P10-029` をCompleteと判定してよい。その場合の次のplanned management IDは `CA-P10-030` とする。

### STOP

WIF / Secret / Codex executionへ進まない。

runner trust / ownership / permission modelがdocumentationと食い違う場合はSTOPする。

Global Mutexの作成/openまたは明示DACLをactual runner identityで安全に成立させられない場合、session-local lockへ勝手にfallbackせずSTOPする。

public repositoryへのunsafe runner exposure、long-lived PAT追加、broad permission expansion、host-wide ACL変更等が必要ならSTOPする。

### Initial recommended routing

- Model: Terra
- Reasoning: High
- Speed: Fast
- Parent + Implementer + Tester
- Stage A終了時にlocal lock / ACL / abandoned handlingをsecurity-focused review
- 全Stage終了後にIndependent Reviewer

---

## 13. CA-P10-030 — Workspace / Git Bash Windows adaptation

### Goal

caller repositoryのautomation-managed workspace lifecycleを成立させ、既存Linux/bash中心のPhase 10資産をWindows + Git Bash上でどこまで安全に再利用できるかを確定する。

対応step: **E**

### Initial expected scope

- controlled caller checkout / workspace
- known base state
- task branch preparationの既存logic再利用
- workspace reuse / cleanup ruleの実装に必要な範囲
- Windows path behavior
- MSYS path conversion
- `HOME`, `RUNNER_TEMP`, `GITHUB_WORKSPACE`等
- `install`, `chmod`, `sha256sum`, `trap`等のactual compatibility
- `git`, `gh` interaction
- existing bash codeのminimal adaptation

### Grounding重点

ここでは「既存bashを多く再利用できる」は仮説として扱う。

実際に成立しない場合、PowerShell全面移植へ勝手に切り替えずSTOPして報告する。

### Completion concept

credentialなしでcaller repoを既知状態へcheckout / prepare / validate / cleanupでき、後続のauth / Codexを載せられる状態にする。

### Initial recommended routing

- Model: Terra
- Reasoning: High
- Speed: Fast
- Parent + Implementer + Tester

---

## 14. CA-P10-031 — WIF / Secret / isolated Local Codex read-only

### Goal

既存のvalidated authentication lifecycleをSelf-hosted persistent Windows hostへ適応し、isolated automation Codex runtimeからread-only Codex taskを1件通す。

対応step: **F + G**

### Initial expected scope

- GitHub OIDC / WIF
- caller Secret selection
- exactly-one-enabled-version preflight
- isolated automation Codex runtime / home
- auth restore
- Codex login validation
- auth baseline / changed-state handling
- candidate Secret persistence / adoption existing logicの適応
- bounded credential locations
- cleanup / residual check
- Local Codex read-only execution

### Grounding重点

- existing WIF / Secret workflow implementation
- actual self-hosted OIDC behavior
- `CA-P10-030`で確認したGit Bash / path compatibility
- normal user Codex runtimeを使わないこと
- credentialのlocal authoritative stateを作らないこと

### STOP

workspace-write、commit、push、Draft PRへ進まない。

WIF trust condition / IAM / Secret isolationのarchitecture変更が必要ならSTOPする。

### Initial recommended routing

- Model: Terra
- Reasoning: High
- Speed: Fast
- Parent + Implementer + Tester + Independent Reviewer

---

## 15. CA-P10-032 — Workspace-write + trusted publication

### Goal

Self-hosted Local Codexにminimal controlled working-tree changeを成功させ、その結果を既存trusted validation / commit / push / Draft PR publication pathへ再接続する。

対応step: **H + I**

### Initial expected scope

- minimal controlled workspace-write
- CodexのGitHub credential isolation
- Codexはworking-tree implementationのみ
- protected-path validation
- Git refs / config / branch / base checks
- auth persistence completion gate
- trusted staging
- implementation commit
- explicit task-branch push
- Draft Pull Request
- cleanup / residual-state validation

### Grounding重点

既存publication logicは「再利用可能なはず」という仮説としてactual workflowを読む。

Linux固有処理、runner-local path、credential helper、Git behaviorに差異があれば同一security boundary内でのみ適応する。

新しいpublication modelへ設計変更しない。

### Completion concept

安全に限定した1件で:

```text
Local Codex
  ↓
working-tree change
  ↓
trusted validation
  ↓
commit
  ↓
push
  ↓
Draft PR
```

を成立させる。

### Initial recommended routing

- Model: Terra
- Reasoning: High
- Speed: Fast
- Parent + Implementer + Tester + Independent Reviewer

---

## 16. CA-P10-033 — Phase 10 E2E validation

### Goal

本来のIssue entry pointからSelf-hosted Local Codexによる実装を経てDraft Pull Requestまで通し、`ROADMAP.md` のPhase 10 completion criteriaを満たしたかを検証する。

対応step: **J**

### Initial expected scope

- real `codex-ready` Issue entry
- caller validation
- availability / dispatch
- managed-area preflight / lock
- workspace
- WIF / Secret / isolated Codex runtime
- Local Codex implementation
- authentication lifecycle
- trusted publication
- cleanup / residual validation
- audit evidence
- final roadmap criteria review

### Phase completion boundary

このtaskが成功しても、Codexが独自に `ROADMAP.md` をPhase 10 Completeへ変更してはならない。

最終報告では:

- completion criteriaごとのevidence
- remaining uncertainty
- Phase 10をCompleteにできる状態か

を報告する。

Phase status更新と次Phase開始はUserの明示判断を待つ。

### Initial recommended routing

- Model: Terra
- Reasoning: High
- Speed: Fast
- Parent + Tester + Independent Reviewer
- implementation fixが必要な場合のみImplementer

---

## 17. 計画の更新

このexecution planも実装結果と矛盾したまま放置してはならない。

read-only groundingまたは実装結果から、今後のtask descriptionに恒常的な修正が必要だと判明した場合:

1. current taskは承認済みscope内で安全に完了できるか判断する
2. plan変更がarchitecture / roadmap / security decisionを伴う場合はUserへ戻す
3. 承認後、`PHASE10_EXECUTION_PLAN.md` をactual stateへ更新する
4. 後続taskは更新後planを読む

一時的な実装詳細まで逐一planへ固定する必要はない。

この文書は、Phase 10中に「何を、なぜ、どの順番で、どこで止まるか」を忘れないための正本として維持する。