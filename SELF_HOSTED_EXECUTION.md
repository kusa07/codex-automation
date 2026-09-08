# Self-hosted Execution 設計

## 1. 目的

この文書は、`codex-automation` が使用する Self-hosted Execution のアーキテクチャを定義する。

Self-hosted Execution は、GitHub-hosted runner ではなく、永続的なローカルPC上で Executor を動作させるための制御された実行経路を提供する。

初期 Executor はローカルの Codex CLI とする。

主目的は、Phase 10 の write-capable Codex execution を実現しつつ、既存の責任分界、認証、検証、公開処理の境界を維持することである。

この文書は、ローカル実行環境とそのライフサイクルを定義する。

アプリケーション固有の責任は再定義しない。

Phase番号、完了状態、実装順序については `ROADMAP.md` を正とする。

---

## 2. 責任分界

責任分界は以下とする。

```text
Caller repository
    = 何を実装するか

codex-automation
    = どのように実行するか
      および
      Self-hosted Execution 環境をどう維持するか

Self-hosted Execution Area
    = ローカル実行を行う場所

Local Codex
    = 実装作業を行う Executor

Google Cloud
    = Codex認証状態の正本保管先
```

Caller repository は Self-hosted Execution Area の内部構造を理解する必要はない。

Self-hosted Execution Area は Caller repository の所有物ではなく、`codex-automation` が管理する実行リソースである。

---

## 3. 全体フロー

初期の Self-hosted Execution 経路は以下とする。

```text
User
  ↓
ChatGPT
  ↓
GitHub Issue
  ↓
Caller Workflow
  ↓
codex-automation
  ↓
実行可否 / runner availability 確認
  ↓
GitHub Actions self-hosted runner
  ↓
Self-hosted Execution Area
  ↓
Local Codex
  ↓
working-tree変更
  ↓
trusted validation / publication
  ↓
Draft Pull Request
```

GitHub Actions self-hosted runner は、許可された job をローカルPCへ届けるための dispatch 手段として扱う。

runner自身は Executor ではない。

初期 Executor は Local Codex とする。

---

## 4. Self-hosted Execution Area

Self-hosted Execution Area は以下のどちらにも置かない。

- `codex-automation` repository の内部
- ユーザーが普段開発で使用している caller repository の working copy

例:

```text
C:\codex-self-hosted\
```

root path は設定可能とする。

Phase 10初期実装では、GitHub Actions self-hosted runner本体はManaged Execution Areaの外部に置く。

概念的なホスト上の構成例:

```text
C:\codex-runner\
    └─ GitHub Actions self-hosted runner本体

C:\codex-self-hosted\
├─ workspaces\
├─ codex-home\
├─ temp\
├─ state\
└─ logs\
```

`C:\codex-runner\` は例であり、runnerのactual pathはbootstrap時に明示的に決定してよい。

ただしrunner directoryはManaged Execution Area schemaの一部ではない。`CA-P10-028`で確立したmanaged rootのknown-entry / unknown-entry fail-closed境界を保つため、normal setup中にrunner directoryをexecution root直下へ追加してはならない。

将来runnerをManaged Execution Area内へ移す場合は、execution-area schema / trust boundary変更として明示的に設計・migrationを行う。

Self-hosted Execution Areaはautomation専用とする。

ユーザーが普段使用している Codex 設定や通常の開発用 repository は、原則として automation 実行には使用しない。

---

## 5. 所有と管理

Self-hosted Execution Area の実体は `codex-automation` repository の外部に存在する。

ただし、その期待状態とライフサイクルは `codex-automation` が管理する。

`codex-automation` は少なくとも以下を定義する。

- 必要なディレクトリ構造
- 管理領域を示す marker
- schema / layout version
- bootstrap
- ensure / preflight
- 排他制御
- execution state
- workspace lifecycle
- 一時 credential lifecycle
- cleanup
- residual-state validation
- audit event
- execution area schema変更時の migration 方針

Self-hosted Execution Area に独立した business logic を持たせてはならない。

実行ルールの正本は version 管理された `codex-automation` 側に置く。

---

## 6. Bootstrap と Ensure

初期構築と通常実行は分ける。

### 6.1 初期 Bootstrap

以下のような操作は、明示的な初期構築として扱う。

- GitHub Actions self-hosted runner の導入
- runner の GitHub への登録
- Windows Service / 自動起動設定
- runnerを実行するWindows identityの確定
- 必要なローカルファイル権限およびlocal lock accessの設定

権限昇格や security-sensitive な初期設定を、通常の Codex 実行中に暗黙に行ってはならない。

runner用の専用local accountはPhase 10必須要件とはしない。ただし、normal executionでrunnerがどのWindows identity / SIDとして動くかは明示的に確定し、そのidentityとlocal filesystem権限およびGlobal named MutexのDACLが整合していることを確認する。

### 6.2 通常の Ensure

Self-hosted 実行前に、`codex-automation` は execution area が期待状態にあることを確認する。

概念:

```text
execution request
    ↓
execution root が存在するか
    │
    ├─ NO
    │   ↓
    │ 管理領域を作成
    │
    └─ YES
        ↓
      ownership marker確認
        ↓
      schema version確認
        ↓
      必須構造確認
        ↓
      安全に補完できる不足だけ作成
        ↓
      実行継続
```

通常の ensure が自動補完してよいものは、原則として「既知の必須空ディレクトリが不足している」など、安全性を判断できる限定された状態とする。

以下のような状態は自動修復せず fail closed とする。

- markerが存在しない、壊れている、または期待した内容でない
- schema versionが一致しない
- active execution stateが残っている
- credential residueが残っている
- 想定外のCodex processが存在する
- workspaceのGit状態が期待値と一致しない
- その他、正常状態かどうかを一意に判断できない状態

設定された path が存在するだけで、その directory を信頼してはならない。

---

## 7. 管理領域の識別

execution root には、`codex-automation` 管理下であることを示す marker を置く。

例:

```text
C:\codex-self-hosted\
    .codex-automation-managed
```

marker は領域の identity を表す不変情報を持つ。

少なくとも以下を含める。

- `managed_by`
- execution-area schema version
- execution-area固有ID
- 作成時刻などの監査用metadata

実行中のjob情報や可変状態は marker に含めず、別の state file で管理する。

例:

```text
state\
  current-run.json
```

marker は「この領域が何者か」を表し、state は「現在どういう状態か」を表す。

設定された root が既に存在するが、有効な marker が無い場合は fail closed とする。

未知の既存 directory を自動的に削除、流用、上書きしてはならない。

---

## 8. Atomic state write

marker および `current-run.json` など、preflightやfail-closed判定の根拠になる state は atomic write で更新する。

概念的には以下の方式を用いる。

```text
state.tmp に完全な内容を書き込む
    ↓
flush / close
    ↓
atomic rename / replace
    ↓
正式なstate fileとして公開
```

読み込み時に以下を検出した場合は正常状態と推測せず fail closed とする。

- fileが存在すべきなのに存在しない
- JSONその他の構造がparseできない
- 必須fieldが欠落している
- schemaが一致しない
- 値同士が矛盾している

壊れた state を normal execution 中に自動修復してはならない。

---

## 9. Persistent state と Ephemeral state

Self-hosted Execution Area 内の情報は、すべて同じ寿命ではない。

### 9.1 Persistent / 再利用可能

execution area内の例:

- 管理領域marker
- schema情報
- sanitized operational state
- 再利用可能なdirectory structure

execution area外のpersistent host componentとして:

- GitHub Actions self-hosted runner本体

が存在する。

runner本体がpersistentであっても、Managed Execution Areaのschema memberとして扱わない。

### 9.2 Runごとに一時的

例:

- task-specific temporary files
- restored Google credentials
- restored Codex `auth.json`
- isolated Codex runtime state
- 一時task metadata
- publication用一時helper

ローカルPC自体がpersistentだからといって、credentialまでpersistentにしてはならない。

---

## 10. 排他制御

Phase 10 の初期 Self-hosted Execution では、1つの execution area で同時に実行できる job は1件だけとする。

複数callerが存在しても、初期実装では安全性と単純性を優先し、execution area全体を直列化する。

排他制御は二重に行う。

```text
GitHub Actions concurrency
        +
local execution lock
```

GitHub Actions concurrency は dispatch / queue 側の競合を減らす。

local execution lock は、実際のpersistent host上で同時実行が起きないことを最終的に保証するための境界とする。

初期実装の local lock は Windows named Mutex とし、session-localな `Local\` namespaceではなくcross-sessionで共有される `Global\` namespaceを使用する。

概念的なMutex名:

```text
Global\codex-automation-<execution-area-id>
```

実際の名前は、managed markerのexecution-area固有IDからdeterministicかつsecretを含まない形で導出する。同一execution areaに対するrunner service / interactive diagnostic process等がWindows sessionをまたいでも同じlockへ収束できることを目的とする。

Global Mutexはdefault broad ACLへ依存せず、明示的なDACL / security descriptorを設定する。normal executionで必要なrunner Windows identityへ必要最小限のMutex accessを与え、`Everyone`等への不要な広いaccessを前提としない。

専用runner accountはPhase 10必須ではないが、runner registration / service setup時にactual Windows identity / SIDをgroundingし、Mutexを安全にcreate/openできることを検証する。必要な権限を成立させられない場合はsession-local Mutexへfallbackせず fail closed / STOPとする。

named Mutex を選ぶ理由は、プロセス異常終了後に abandoned mutex として検出可能であり、単純な lock file よりも stale lock 判定を実装しやすいためである。

abandoned mutex を検出した場合は「lockが空いた」とみなしてそのまま続行せず、前回実行が正常終了しなかった兆候として扱う。

.NETのabandoned Mutex検出では、exceptionが通知された時点で呼び出し側がownershipを取得している場合がある。そのため初期実装は以下の順序を守る。

```text
ABANDONED_LOCK_DETECTED
    ↓
Mutex ownershipは保持
    ↓
current-run / residual state確認
    ↓
payloadは実行しない
    ↓
曖昧stateを自動修復・正常化しない
    ↓
finally相当でMutex ownershipをrelease
    ↓
fail closed
```

abandoned detection後にownershipをreleaseせずprocessを終えることを正常経路にしてはならない。

lock file方式へ変更する場合は、staleness判定基準を別途明示的に設計・承認する。

---

## 11. Execution ID と二重実行防止

各 execution には一意な Execution ID を付与する。

Execution ID は少なくとも caller identity と GitHub Actions run identity を組み合わせて導出できるものとする。

例:

```text
repository_id
+ github_run_id
+ github_run_attempt
```

実行開始時に `state/current-run.json` へ記録する。

同一Execution IDの再実行、または別Execution IDのactive stateが残っている場合は、Codexを自動起動しない。

中断された execution は自動 resume / 自動 replay しない。

初期方針は以下とする。

```text
INTERRUPTED
    ↓
自動再開しない
    ↓
preflight / recovery判断
```

GitHub Actions側のretryやrunner再登録だけを根拠に、同じ作業をローカルで自動的に二重実行してはならない。

---

## 12. Workspace lifecycle

Caller repository の作業は automation 管理下の workspace で行う。

例:

```text
workspaces\
    interest-gacha\
    project-b\
```

または run 単位の構造でもよい。

ユーザーが普段使っている working copy とは分離する。

Codex実行前には、repositoryが期待した既知状態であることを確認する。

workspace再利用を許可する場合でも、既存Git stateを無条件に信用してはならない。

未知または矛盾した状態は、明示的な recovery procedure が無い限り fail closed とする。

---

## 13. Codex runtime の分離

automationから起動するCodexは、原則としてユーザーの通常のCodex runtime directoryを使用しない。

Self-hosted Execution Area 配下、または automation 専用 location を使用する。

例:

```text
codex-home\
    <caller-or-run-context>\
```

目的は以下。

- automation state が通常のCodex利用へ影響しない
- 通常利用のCodex state がautomationへ影響しない
- stale credentialが暗黙再利用されない
- caller間でmutable runtime stateを不用意に共有しない

caller単位、run単位、またはhybridのどれにするかは、既存のauthentication serialization modelを壊さない範囲で決定する。

---

## 14. Authentication lifecycle

Codex認証状態のpersistentな正本は、引き続きGoogle Cloud Secret Managerとする。

Self-hosted化しても、callerごとの認証分離原則は変更しない。

概念:

```text
Secret Manager
    ↓
認証済み auth.json をrestore
    ↓
temporary local Codex runtime
    ↓
Codex execution
    ↓
認証状態変更を検証
    ↓
必要ならcandidateをpersist
    ↓
validation成功後のみadopt
    ↓
ローカルcredential削除
```

persistent host上のローカル `auth.json` を正本として扱ってはならない。

既存の exactly-one-enabled-version および fail-closed rule は維持する。

---

## 15. Credential の書き込み範囲

credential residueの検査をPC全体へ広げるのではなく、credentialを書き込んでよい場所を最初から限定する。

`codex-automation` が管理する credential は、定義済みの automation-owned location 以外へ書き込んではならない。

例:

```text
codex-home\<execution-context>\
temp\<execution-context>\
```

preflight / cleanup / residual check は、これらの既知locationを検証対象とする。

未知の場所へcredentialを書き込む設計変更は、明示的なsecurity reviewなしに導入してはならない。

---

## 16. Secure delete の境界

Self-hosted Execution は、credentialの物理的・forensicな完全消去を保証しない。

SSDのwear leveling等により、通常のfile overwriteを行っても物理媒体上の完全消去を保証できない場合があるためである。

`codex-automation` の責任は以下とする。

```text
credentialを書いてよい場所を限定
    ↓
必要な時間だけ存在
    ↓
通常削除
    ↓
既知locationに存在しないことを確認
```

ディスクのforensic recovery耐性はhost securityの範囲とする。

---

## 17. 実行前 residual-state check

Self-hosted machine はjob間で状態が残るため、前回cleanupが成功したことを前提にしてはならない。

毎回job開始時に残留状態を確認する。

概念:

```text
job start
    ↓
managed area は正常か
    ↓
schema は一致するか
    ↓
local lock は正常か
    ↓
active state は残っていないか
    ↓
credential residue はないか
    ↓
unexpected temporary state はないか
    ↓
unexpected Git state はないか
    ↓
unexpected Codex process はないか
    ↓
safe
    ↓
execution開始
```

unexpected sensitive residue を単純に上書きしてはならない。

security上意味のある不明状態は fail closed とする。

このpreflightは、前回jobがcleanup成功を報告していても実施する。

---

## 18. 実行後 cleanup

Codex実行が成功でも失敗でも、可能な限りcleanupを行う。

削除対象例:

- restored Codex auth files
- Google credential files
- temporary GitHub credential helpers
- privileged execution contextを含む一時task file
- その他run単位のsecret / token
- 自分が作成した `state/current-run.json`

normal execution lifecycleでは、payload / commandのsuccessまたはfailureを保持したままcleanupを行う。

概念:

```text
payload / command resultを保持
    ↓
自分が作成したrun-local stateをcleanup
    ↓
post-run residual-state validation
    ↓
idle preflight
    ↓
結果を確定
    ↓
local Mutex release
```

command failureだからという理由でpost-run validationを省略してはならない。

一方、中断・abandoned・identity不一致等でstate ownershipが曖昧な場合は、未知stateを削除して正常化してはならない。自分が安全に所有していると確認できるrun-local stateだけを通常cleanup対象とする。

cleanup後は residual-state validation を行う。

必要なsecurity cleanupまたはpost-run validationが失敗した場合、Codex処理自体が成功していても、Self-hosted Execution全体を完全成功として扱わない。

---

## 19. Interrupted execution

persistent hostでは、GitHub-hosted ephemeral runnerよりも中断後の残留状態を意識する必要がある。

例:

- PC shutdown
- runner process停止
- Windows再起動
- network loss
- workflow cancellation
- process crash
- power loss

そのためpost-job cleanupだけでは不十分である。

次回job開始時にpreflightを行い、中断jobの残留状態がsecurity上曖昧なら fail closed とする。

abandoned mutex、active `current-run.json`、credential residue等は中断の兆候として扱う。

自動破壊的recoveryは原則としない。

---

## 20. Runner availability

runner availability確認と実行は別責任とする。

概念:

```text
task request
    ↓
availability pre-check
    ↓
実行可能か
    │
    ├─ YES
    │    ↓
    │ self-hosted execution
    │
    └─ NO
         ↓
       NOT_EXECUTED
```

runnerが利用できない状態は Codex implementation failure とは扱わない。

将来的なstatus例:

```text
RUNNER_OFFLINE
RUNNER_BUSY
RUNNER_INELIGIBLE
```

正確なfailure / status contractは主にPhase 11で定義する。

availability checkはadvisoryである。

checkとjob dispatchの間のraceを完全には防げない。

最終的なschedulerはGitHub Actionsとする。

---

## 21. GitHub self-hosted runner の役割

GitHub self-hosted runner は、GitHub ActionsとローカルPCをつなぐ dispatch mechanism である。

task semanticsの所有者ではない。

implementation agentでもない。

概念:

```text
codex-automation
      ↓
GitHub Actions
      ↓
self-hosted runner
      ↓
Local Codex
```

runner本体のphysical homeはManaged Execution Area外のpersistent locationとする。runnerをexecution-area schemaへ含めない。

runner registration scope、labels、eligibility、repository binding、execution account / service modeは明示的に設計・groundingする。

専用runner accountは必須ではないが、actual Windows identity / SIDは明示的に確定し、Global named Mutex DACLと必要なlocal filesystem permissionがそのidentityに対して成立することを検証する。

GitHub上のresource bindingがcaller側に必要であっても、Self-hosted Executionという機能の論理的所有者は `codex-automation` とする。

---

## 22. Codex の責任

Local Codexは実装作業を担当する。

責任例:

- validated taskを読む
- repository-local `AGENTS.md` を読む
- 関連documentationを読む
- 実装についてreasoningする
- 許可されたworking-tree fileを変更する
- 許可されていれば適切なtestを実行する

以下はCodexの責任にはしない。

- runner管理
- credential lifecycle
- execution-area lifecycle
- branch authorization
- GitHub credential管理
- publication policy

Phase 10の既存境界は維持する。

```text
Codex
    = working-tree implementation

trusted automation
    = validation + commit + push + Draft PR
```

明示的に設計変更するまでは、この境界を変更しない。

---

## 23. Caller isolation

Self-hosted Executionでもcaller間の分離を維持する。

caller repositoryは、他callerの以下を引き継いではならない。

- authentication state
- temporary credentials
- task files
- workspace modifications
- Codex runtime state
- publication state

初期実装では、再利用効率より単純で安全な分離を優先する。

multi-caller optimizationやshared-runner policyはPhase 12で見直してよい。

---

## 24. Threat model

Self-hosted Execution は、ユーザー自身が管理する trusted Windows PC 上で動作することを前提とする。

`codex-automation` が主に防御対象とするのは以下である。

- 不正または未承認のGitHub / Issue経路からの実行
- caller間の状態混入
- credential residue
- 中断jobによる曖昧な状態
- 誤ったworkspace再利用
- concurrent execution
- Codexとtrusted publication境界の逸脱

以下は初期Self-hosted Executionの防御保証範囲外とする。

- 悪意あるlocal administrator
- OS自体の侵害
- malware / rootkit等によるhost compromise
- 物理アクセスを得た攻撃者への完全な耐性
- raw disk forensic recoveryへの完全な耐性

BitLocker等のdisk encryptionはhost securityとして推奨できるが、Phase 10のSelf-hosted Execution機能そのものの必須要件とはしない。

---

## 25. Security model

Self-hosted execution machine は persistent security boundary として扱う。

GitHub-hosted runnerと異なり、job終了後もローカルstateが残る可能性がある。

そのため少なくとも以下を前提とする。

- 明示的managed-area ownership
- known-state preflight
- execution area全体のcross-session排他制御
- Global named Mutexへの明示的least-privilege DACL
- Execution IDによる二重実行防止
- 必要時のみcredential restore
- credential locationの限定
- execution後credential削除
- residual-state validation
- caller isolation
- restricted GitHub permissions
- 既存WIF / Secret Manager authorization維持
- Codexとtrusted publicationの責任分離維持
- ambiguous stateのfail-closed

repository privacyは追加防御にはなるが、これらsecurity controlの代替にはしない。

---

## 26. Auditability

security上重要なイベントは、credential内容を含まないsanitized eventとしてGitHub Actions logへ記録する。

例:

```text
EXECUTION_STARTED
PREFLIGHT_PASSED
LOCK_ACQUIRED
ABANDONED_LOCK_DETECTED
CREDENTIAL_RESTORED
CODEX_STARTED
CODEX_FINISHED
CREDENTIAL_REMOVED
CLEANUP_PASSED
FAIL_CLOSED
EXECUTION_FINISHED
```

GitHub Actions logは、ローカルPC外にも残る主要なaudit trailとして扱う。

`logs\`配下のローカルログは詳細なoperational diagnosticsの補助として扱う。

ログには以下を含めてはならない。

- `auth.json`本文
- access token
- refresh token
- Secret payload
- Google credential本文
- その他credentialそのもの

本格的な集中監査ログや長期retention設計は、Phase 11以降で検討してよい。

---

## 27. Schema migration

normal execution中にexecution-area schemaを自動migrationしてはならない。

例:

```text
current required schema = 1
execution area schema = 1
→ OK
```

```text
current required schema = 2
execution area schema = 1
→ STOP
```

schema mismatchを検出した場合は fail closed とし、明示的なsetup / migration operationを要求する。

migration処理は通常jobとは分離し、明示的に実行・検証できるようにする。

自動migrationよりも「古ければ止まる」を初期方針とする。

---

## 28. Phase 10 の段階的検証

Self-hosted Executionは段階的に導入する。

推奨順:

1. Self-hosted Execution architectureを承認
2. bootstrap / managed execution areaを作成
3. marker / schema / atomic state writeを検証
4. ensure / preflightを検証
5. Global local lock / DACL / abandoned lock / post-cleanup behaviorを検証
6. self-hosted runnerを登録・確認
7. credentialを使わないinert jobを実行
8. workspace作成・cleanupを検証
9. self-hosted pathからWIF / Secret Manager accessを検証
10. isolated Codex authentication restore / cleanupを検証
11. Codex read-only taskを1件実行
12. minimal controlled workspace-writeを1件実行
13. 既存trusted publication pathを接続
14. Issue → Codex → Draft Pull RequestをE2E検証

Phase 10は、既存 `ROADMAP.md` のcompletion criteriaを満たすまではCompleteとしない。

---

## 29. 将来の Executor abstraction

初期Executorは Local Codex とする。

```text
Self-hosted execution
    ↓
Local Codex
```

将来的には以下のような拡張を妨げない。

```text
Execution backend
    ├─ Self-hosted / Local Codex
    ├─ Codex Cloud
    └─ その他のapproved executor
```

ただしExecutor abstraction自体はPhase 10の必須要件としない。

まずはSelf-hosted / Local Codexの1経路を安定して成立させる。

---

## 30. Non-goals

初期Self-hosted Executionでは以下を行わない。

- 汎用remote execution platformを作る
- 任意repositoryからローカルPC上でcode execution可能にする
- ローカルPCをpublic Internetへ直接公開する
- GitHub Actionsを現在のorchestration mechanismから外す
- caller間で無制限にworkspaceを共有する
- local credentialを正本とする
- ambiguous stateから破壊的に自動復旧する
- Codex Cloudを実装する
- alternative executorを実装する
- Phase 12前にmulti-repository optimizationを完成させる
- trusted hostそのものの物理・OS・malware securityを`codex-automation`だけで保証する
- forensic secure eraseを保証する

---

## 31. 初期アーキテクチャ判断

| 項目 | 初期判断 |
|---|---|
| 機能の所有者 | `codex-automation` |
| 物理execution area | Git repository外 |
| execution area lifecycle | `codex-automation` が管理 |
| Runner physical home | Managed Execution Area外のpersistent location |
| Runner account | explicit Windows identityを確定。専用accountはPhase 10必須ではない |
| 通常ユーザーworkspace | 原則使用しない |
| 通常ユーザーCodex home | 原則使用しない |
| 初期Executor | Local Codex |
| Dispatch | GitHub Actions self-hosted runner |
| Execution area同時実行 | 1 job |
| GitHub側排他 | GitHub Actions concurrency |
| Local側排他 | Windows `Global\` named Mutex |
| Mutex identity | execution-area固有IDからdeterministicに導出 |
| Mutex access | explicit least-privilege DACLをrunner Windows identityへ設定 |
| Abandoned mutex | ownership保持中にresidual inspection、payload禁止、release後fail closed |
| Execution ID | caller + GitHub run identityから一意化 |
| Marker | execution area identity / schema |
| Current state | `state/current-run.json` 等で分離 |
| State write | atomic write |
| Authの正本 | Google Cloud Secret Manager |
| Credential location | automation-owned既知locationに限定 |
| Forensic secure delete | 非保証 |
| Host前提 | trusted Windows PC |
| 既存WIF model | 維持 |
| Caller Secret isolation | 維持 |
| Codex publication権限 | working-treeのみ |
| Commit / push / PR | trusted automation |
| Pre-job residual check | 必須 |
| Post-job cleanup check | current-run cleanup後のresidual validation / idle preflightを含め必須 |
| Audit trail | sanitized GitHub Actions logを主要経路とする |
| 未知の既存directory | fail closed |
| Schema mismatch | normal job中は自動migrationせずSTOP |
| Multi-repository optimization | 将来 |
| Alternative executors | 将来 |

---

## 32. Phase 10 作業指示単位との対応

この文書の段階的検証stepは、Codexへ渡す実作業指示では `PHASE10_EXECUTION_PLAN.md` に定義した以下の6単位へまとめて進める。

| 管理番号 | 対応する段階 | 主目的 |
|---|---|---|
| `CA-P10-028` | B | Managed Execution Area実装 + negative-path検証 |
| `CA-P10-029` | C + D | self-hosted runner / Git Bash / Mutex / availability / inert dispatch |
| `CA-P10-030` | E | workspace lifecycle + Windows / Git Bash適応 |
| `CA-P10-031` | F + G | WIF / Secret / isolated Codex runtime + read-only |
| `CA-P10-032` | H + I | workspace-write + trusted publication再接続 |
| `CA-P10-033` | J | Issue → Local Codex → Draft PR E2E validation |

この対応はvalidation stepを省略するものではない。複数のlogical stepを同一grounding contextとfailure domainの中でまとめて実装・検証するための作業指示単位である。

各管理番号の具体的なscope、grounding checklist、STOP条件、result contractは `PHASE10_EXECUTION_PLAN.md` を正とする。

各taskはwrite前にread-only groundingを行い、計画上の想定をactual repository / host / previous-task resultと照合する。重大な差異がある場合は、計画に合わせて現実を無理に変更せず `STOP_AND_REPORT` としてUser / ChatGPTへ戻す。