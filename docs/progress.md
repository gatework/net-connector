# 实施记录

记录每次实施的范围、验证命令与证据边界。v0.6.0 之前的历史记录见 Git 历史。

## 2026-11-09 Go 惯用法、去样板与批量下发

按已批准方案（`~/.claude/plans/go-go-net-connector-dapper-grove.md`）在工作区实施，未提交、未发布。基线：除 `internal/cli` 的 `TestInteractiveDeclinedOptionalEnvContinues` 在本机 PTY 下挂起至超时（改动前即如此，未修改该用例）外，`GOWORK=off go test ./...` 全部通过。

- 现代化：`GOWORK=off go fix ./...`（errors.AsType、maps.Copy、slices.ContainsFunc/Backward/Contains、strings.SplitSeq、range int），删除被内联后未使用的指针辅助函数；`.golangci.yml` 启用 modernize、errorlint（测试除外）与 revive 的 unexported-return、receiver-naming。`pureDeviceRejection`、`primaryDiagnosticError` 保留顶层判断并注明原因。未启用 revive `exported`：缺失文档注释数量大，另行处理。
- 枚举单一拥有者：`batchreport.SuccessPolicy`/`Layout`、`netdisco.CacheMode`、`inventory.MatchMode`、`config.FieldKind`；config、bootstrap、CLI、fleet、display 与补全表改用这些定义，字符串值与 CLI 参考不变。`netdisco.FetchOptions.Mode`、`Cache.Fetch` 改为 `CacheMode`。
- 厂商样板：家族构造函数返回导出类型（`h3c.Dialect`、`h3c.WirelessDialect`、`cisco.IOSDialect` 等）；`driver.TopologyReader` 组合三项只读拓扑能力；`driver.PositionMarkerCommandErrors`、`driver.YesNoConfirmations` 去除 H3C/Huawei 逐字重复；`TFTPBase` 直接持有 `TFTPOptions`，文件名长度与源接口名改为具名常量，参数错误包装 `ErrInvalid` 并只标明字段名。`vendors/profiles_test.go`、parity 与能力契约测试未改断言，全部通过。
- 破坏性配置变更（用户确认）：删除 `tftp.h3c_source_file`、`tftp.h3c_wireless_source_file`、`tftp.huawei_source_file` 及对应环境变量；出现时返回 `FieldError{Problem:"removed", Replacement}`，CLI 提示改用 `tftp.source_files.<平台>`。迁移见 `docs/api-migration.md`。设备凭据键集中到 `credentialKeys`，查找顺序与空白回退语义不变。
- 计划预览：`workflow.NewPlanView` 返回类型化 `PlanView`，TFTP 传输字段在同一处生成，去掉 `[]map[string]any` 类型断言；先录制 `internal/workflow/testdata/plan_view_*.json` golden，重构后字节一致。
- 新增 `netman push plan|run`：连接前校验全部脚本；fleet 规划沿用设备筛选；每台设备一次操作租约内 `ExecuteScript`，可选 `SaveConfig`（仅 ValidateSave 正向回执算保存）；失败不重试、不重放；`--stop-after-failures` 只阻止未开始的设备；`report.json` 区分 AcceptedCommands 与 Attempts。指定 `--save` 时未声明保存脚本的平台在规划阶段记为 `save_unsupported` 并跳过；脚本中的 C0 控制字符（制表符除外）在连接前拒绝。

发布准备：在 origin/main（v0.5.0，`f0772b2`）之上重新应用并解决 config、CLI 与迁移文档冲突，版本定为 v0.6.0（含破坏性配置变更）。随后将 go-expect 从 v0.4.1 升级为正式 v0.5.0：proxy.golang.org 与 sum.golang.org 哈希一致，标签指向发布说明记录的测试提交 `33bf675`；本模块无需源码改动，全包 race 测试与 vet 通过。验证：`GOWORK=off go test -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS；`go test -race` 覆盖 internal/...、fleet、vendors/...、config、netdisco、inventory、storage、transfer PASS；`go vet ./...` PASS；golangci-lint v2.15.0 0 issues；`docs/cli-reference.md` 由 `-update-cli-reference` 重新生成。push 使用模拟传输验证拒绝后不再发送、保存未确认、失败上限与脚本无效时不读清单不建设备；不代表真实设备验收。

## 2026-11-09 v0.7.0 重构：清除兼容代码（Phase 1）与平台驱动（Phase 2）

按批准方案（`~/.claude/plans/go-go-net-connector-dapper-grove.md`）在 v0.6.0（`5fb812e`）上实施，未提交。

- Phase 1：删除 deadcode 报告中不被下游使用的 API（见 `api-migration.md` 的 Removed APIs）；`textfsm` 模板索引及两个无引用模板删除，夹具测试改为显式模板路径，Filldown 状态隔离改用内联模板；`netdisco` 旧 `NewCache` 身份路径与遗留缓存迁移测试删除，缓存类型改为包内私有；`config.Load(ctx, …)` 取代兼容包装；删除 `DOTENV_LINEBREAK_MODE=legacy`、旧 `Authenticated()` 钩子拒绝分支；Ruby 对齐测试改名为 `contracts_golden_test.go`、夹具改名 `testdata/device-contracts.json`，断言不变；删除 `scripts/reference-fixtures.rb`。核实后保留 `verify-expect-source.py`（go-expect 候选验证）与 `verify-firemon-source.py`（Firemon 适配器为第三个下游，锁定 v0.2.0），二者并非 Ruby 工具。`docs/design.md` 取代 implementation-plan 与 decisions；历史计划、基线日志与 quality-evidence 从仓库删除（Git 历史保留）。
- Phase 2：`connector.Profile` 拆为 `Terminal` + `Driver`，可选钩子为 `CommandPreparer/CommandObserver/LoginInspector`；`dialect.Platform` 内嵌 `connector.Driver` 并含 `MatchInventory`；`driver.Base` 取代 `BaseProfile/FinishProfile/ProfiledPlatform`；H3C 规则号钩子、Radware HA 状态成为平台方法；每个家族新增 `capabilities_test.go` 编译期能力断言（与能力矩阵一致）。`LegacySSH*` 更名 `LegacyCrypto*`。CLI 尚未开放 `AllowLegacyCrypto` 配置项，旧设备弱加密恢复目前仅库 API 可用。
- 已删除的不可能场景：`fleet` 中"配置采集工厂返回 nil"子用例（新契约下 nil 即通用采集）。

验证：`GOWORK=off go test -race -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS；`go vet ./...` PASS；golangci-lint v2.15.0 0 issues；`check-architecture.py`/`test_architecture.py` PASS。

## 2026-11-10 v0.7.0 重构：阶段流水线与统一报告（Phase 3）、CLI 用例（Phase 4）、运维能力（Phase 5）

- Phase 3：`internal/workflow` 以 `Stage`/`Operation`/`Session`/`Evidence` 与 `Runner.Execute` 取代 4 套执行循环；`Session` 懒打开并记录 authenticate 阶段（TFTP 在归档事务内才打开，保留"先准备归档、后上传"的顺序）；首个失败阶段拦截后续阶段并记为 skipped；`Evidence.MarkPartial/MarkReview` 区分部分完成与需复核。拓扑 apply 为 `Operation.Then` 第二轮，`Before` 先写 `scripts/` 与 `topology-plan.json`。统一报告 schema v3 由 `internal/batchreport` 拥有（含导出选择规则）；删除 `fleet.Run/Report/Diagnostic`、Ruby 错误类型映射、`internal/topologyreport` 与旧 workflow 文件。工作者以 `Goexit` 退出时该设备记为 failed（`internal_error/worker`），批次仍写报告。备份与 TFTP 新增 `--save` 阶段。偏离方案：未持久化 `report.txt`（文本由 CLI 从报告渲染，避免业务层依赖呈现）。
- Phase 4：`internal/cli` 每个业务命令为 `useCase`（`prepare` 离线校验、`run` 执行），删除执行分派 switch；未拆分平铺 `options` 结构，留待后续。
- Phase 5：`netman exec`（`driver.ReadOnlyCommands`，12 个平台均声明；重定向类管道拒绝）、`netman backup remote`（Juniper 原生导出，远端文件名为 IP+时间戳，密码仅取 `NC_REMOTE_BACKUP_PASSWORD`）、`netman backup diff`（`internal/textdiff` Myers 行级 diff，与 GNU `diff -U2` 输出一致）、跳板机 `-J`（参数注入与 Telnet 组合拒绝）、登录提示前连接重试（refused/no route/timeout，认证失败零重试，取消即停）；修正"无路由/连接超时"被误报为 authentication_error。

验证：`GOWORK=off go test -race -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS；`go vet ./...` PASS；golangci-lint v2.15.0 0 issues；`check-architecture.py`/`test_architecture.py` PASS；`go mod tidy -diff` 无差异；`deadcode ./cmd/...` 仅剩脱敏方法与供下游复用的公开 API。模拟传输覆盖：阶段拦截、认证阶段失败、三种策略、取消、归档上传→报告→移动后导出、deploy 拒绝后不再发送、保存未确认为 partial、exec 写命令零连接、Juniper 导出命令字节与回执解析、diff 退出码、重试边界与跳板机参数。未在真实设备、真实跳板机或远端 SCP/FTP 服务器上验证。

发布准备：版本定为 v0.7.0；更新 `scripts/verify-consumer.py` 至新 API（平台即 Driver、`StaticDriver`、`Pool.Prepare(ctx, nil)`）并覆盖新命令帮助，本地 PASS；三个 fuzz 目标各 20000 次 PASS。

## 2026-11-11 shared Go standard

Adopt go-standards v1.0.2 through standard.mk, the distributed lint configuration and architecture.yaml. Keep the project architecture test, installed archive-worker, PostgreSQL, bounded fuzz and independent consumer checks under make check. Extract phase helpers without changing failure receipts, cache-only password handling, cancellation or cleanup order. The release uses published go-expect v0.6.0 and migrates the internal MatchOption call; the connector public API is unchanged.

## 2026-11-12 v0.8.0 Phase 1：术语统一与清理

按批准方案（`~/.claude/plans/go-go-net-connector-snappy-wirth.md`）在工作区实施，未提交、未发布。

- 术语：`vendors/dialect` → `platform`；家族类型 `Dialect` → `Platform`；`fleet.Record.Vendor`、`Mapping.Connector`、`topology.Plan.Vendor` → `Platform`；`Record.BackupFilename(style)` → `Filename()`（`"ip"` 分支无调用方，已删）。本机无 gopls，改名用 `git mv` + 批量替换，每一步由 `go build`/`go vet` 校验；两处测试里与包同名的局部变量手工改名。
- 运维表面（用户确认，不留旧名）：配置键、`NC_*` 环境变量、`--platform`/`--exclude-platform`、设备规则键 `platform`；报告 schema 升为 v4；`docs/cli-reference.md` 由 `-update-cli-reference` 重新生成。
- 类型化：`batchreport.Status`/`Outcome`/`BatchStatus`，`Stage.Admit` 返回 `Status`；`connector.LogLevel`；`connector.LoginCommitter` 取代匿名接口断言。计划预览的状态计数改为按键排序输出（原先随 map 遍历顺序变化）。
- 偏离方案：拓扑证据没有移入 `batchreport`（那会让 `config` 经 `batchreport` 传递依赖 `topology`/`connector`）；改为 `workflow.Evidence.Topology` 类型化字段，写报告时才放入 `Artifacts.Topology`，5 处类型断言已消除。
- 行为变化（一处）：清单标签规范化统一为 `platform.NormalizeLabel`，Registry 侧现在也去掉首尾分隔符（如 `"(H3C) S5500"` 规范化为 `h3c s5500` 而不是带前导空格），与 fleet 规则侧一致。
- 删除：`config.removedFields` 及拒绝逻辑、`FieldError.Replacement`、`docs/api-migration.md`、`scripts/verify-firemon-source.py`、`scripts/verify-expect-source.py`；旧版发布说明中的迁移文档链接改为文字说明。`connector.isNilValue` 与 `archive.nilEndpoint` 合并为 `internal/nilcheck.IsNil`；`driver.copyTerminal` 由 `Terminal.Clone` 取代。
- 现代化：`slices.Clone`、`slices.Sorted(maps.Keys)`、`slices.SortFunc/SortStableFunc`；`go fix ./...` 无其他改动。
- 测试文件按被测行为改名（`final_fix`、`round3`、`refinement`、`regression`、`quality`、`v2`、`unified`、`minimal`、`conventions`、`profile*`），断言未改。

## 2026-11-12 v0.8.0 Phase 2：平台模型收敛

- 通用层去厂商化：`Terminal.PrivilegedPrompt`（Huawei 声明 `\]\s*\z`）取代 `connector` 中“提示符含 `]` 即已提权”的判断；`LoginState.Labels`/`Device.LoginLabel` 取代 Radware 专属的 `HAState`；`driverHooks` 通过未导出的 `hookSource` 接口解析适配器钩子，不再对具体类型分支。新增设备级测试：未声明 `PrivilegedPrompt` 的平台即使提示符是 `[sw]` 也会发送提权命令。
- 能力数据类型归位到 `topology`/`transfer`，`platform` 只剩 `Platform`、`Registry`、`Identity`、诊断错误。因 `vendors` 现在导入这两个包，它们的测试改为外部测试包（`topology_test`、`transfer_test`），少量内部访问经 `topology/export_test.go` 桥接；`vendors/internal/topology` 更名 `topoparse` 以免与公开包同名。
- `transfer.TFTPPolicy` 由 11 个方法减为 6 个：4 个常量 getter 合并为 `Traits()`，源文件发现成为可选的 `SourceFileResolver`（只有 H3C 家族实现）。
- `fleet.NewPlan` 不再判定能力：删除 `Mode`/`capability`，由 `workflow.planFor` 注入操作各阶段的 `Admit`。顺序为 准入 → 每平台抽样 → 目的文件仲裁；此前 deploy/exec/remote/topology 都以 `"backup"` 模式建计划，且被阶段跳过的设备会占用抽样名额。workflow 的 Backup/Deploy/Exec/RemoteBackup 改为接收清单行。
- `netman platform list`：能力矩阵由 `workflow.CapabilitiesOf` 生成，与阶段准入使用同一组断言；`vendors/README.md` 的手写矩阵改为引用该命令。输出与原手写矩阵逐项一致。

验证：`GOWORK=off go test -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS；`go vet ./...` PASS；golangci-lint v2.15.0 0 issues；`check-architecture.py` PASS。

## 2026-11-12 v0.8.0 Phase 3：变更前后快照与差异

- `deploy` 流水线为 `snapshot_before → execute → save → snapshot_after → diff`，默认开启，`--no-snapshot` 关闭；删除 `--backup`/`DeployOptions.Backup`。变更前快照写入 `<批次>/before/`，变更后快照写在批次根目录并作为 `artifacts.backup`（因此 `backup export`/`backup diff` 对 deploy 批次继续可用，这一点与方案中的 `after/` 目录不同），差异写入 `<批次>/diff/`，报告新增 `artifacts.change`。
- 失败语义：变更前快照失败时不发送任何脚本字节，设备记为 `failed`（不是 `partial`）；脚本被拒后保留变更前快照且不采集变更后快照；不自动回滚、不重放。接受全部命令但前后配置一致的设备在报告中提示“配置无变化”。
- 顺带修正：`deploy`/`exec` 帮助与 README 示例里的筛选值原为 `cisco`（不是合法平台键，会被规则校验拒绝），改为 `cisco_ios`。

验证：`go test ./internal/...` PASS。模拟设备覆盖：成功下发后 diff 含新增行、`--no-snapshot` 只发送脚本、变更前采集被拒时设备只收到采集命令、脚本被拒后变更前快照文件仍在。未在真实设备上验证。

## 2026-11-12 v0.8.0 Phase 4：提交模型平台的下发

- 新增可选能力 `connector.Committer`（`CommitTraits`、`CandidateScript`、`ValidateCommit`）与 `Operation.Commit`：整份包装后的脚本在发送前校验，一次租约内执行，失败即退役会话，不重放。`driver.CandidateSteps`/`driver.ValidateCommit` 为家族包共用；保存确认与提交确认共用同一个逐步校验 `stepConfirmed`（正向回执行且无失败字样）。
- Juniper：`configure exclusive` → 脚本 → `commit check` → `commit`（或 `commit confirmed N` 后再 `commit`）→ `exit`；回执为 `commit complete`。`commit check` 被拒时不发送 `commit`，会话退役，exclusive 候选随会话丢弃。
- Palo Alto：`configure` → 脚本 → `commit`（超时 10 分钟）→ `exit`；回执为 `Configuration committed successfully`。候选配置跨会话共享：提交前失败的设备结果记为 `candidate_dirty`，不自动 revert。
- 流水线：`ExecuteStage` 在提交模型平台走 `Operation.Commit`，脚本计数只统计脚本自身的行；`SaveStage` 在这些平台准入但不发送任何命令（提交即持久化），因此 Juniper/Palo Alto 不再因 `--save` 被整台跳过。`--commit-confirm` 对不支持的平台在计划阶段记为 `commit_confirm_unsupported`，该状态不属于有意跳过，批次为未完成。`netman platform list` 增加“提交”列。
- **证据边界**：提示符、命令输出与回执文本来自公开文档，没有实机样本；测试使用模拟对端逐字节断言发送序列。若实机回执文本不同，结果是 `commit_unconfirmed`（未确认），不会误报成功。未在真实 Junos/PAN-OS 设备上验证。

验证：`GOWORK=off go test -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS。

## 2026-11-12 v0.8.0 Phase 5：设备事实采集

- 新公开包 `facts`：`Facts`、能力接口 `Collector`、`Commands`（连接前用平台自己的只读分类校验每条事实命令）与 `Collect`（一次租约内执行并解析）。`driver.FactsReader` 以内嵌 TextFSM 模板读取拼接后的输出。
- 首批平台：`cisco_ios`、`cisco_nxos`（`show version`）、`h3c`/`h3c_wireless`（`display version` + `display device manuinfo`）、`huawei`（`display version` + `display esn`）、`juniper`（`show version` + `show chassis hardware`）、`fortinet`（`get system status`）。其余平台未声明能力，计划阶段记为 `unsupported_operation`。运行时长仅保留设备原文，Juniper/Fortinet 不采集。
- `netman facts plan|run`：`FactsStage` 把采集值与清单的 `model`/`serial`/`os_ver` 比对，不一致的字段名写入 `artifacts.facts.mismatches`，设备结果为 `inventory_mismatch`（部分完成，需复核）。清单一侧为空的字段不比较；型号与版本按规范化后互相包含判定。偏离方案：没有另写 `facts.json`，事实已在 `report.json` 中。
- **证据边界**：模板依据厂商公开的命令参考编写，夹具不是生产设备抓取；不同版本的输出差异会表现为 `unrecognized_output` 或字段缺失，不会产生错误的事实。未在真实设备上验证。

验证：`GOWORK=off go test -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS；`check-architecture.py` PASS（40 个生产包）。每个模板有完整、缺可选行、无关输出三类夹具。

## 2026-11-12 v0.8.0 Phase 6：本地静态清单

- 新配置 `inventory.source`（`netdisco` 默认 | `file`）与 `inventory.file`（`NC_INVENTORY_SOURCE`、`NC_INVENTORY_FILE`；路径按配置来源解析）。`source=file` 时必须给出文件，且不能同时配置 `netdisco.url`/`netdisco.query`；文件清单每次读取，不进缓存。
- 新公开包 `inventoryfile`（方案中写的是 `inventory.ReadFile`；放进 `inventory` 会让这个叶子包经 `config` 依赖 `archive`/`transfer`/`connector`，因此单独成包）。YAML 为根 `devices:` 列表，CSV 为表头加数据行；经 `config.ReadFile` 取得 16 MiB、非阻塞打开与取消边界。地址无效、带 zone、重复（含不同写法的同一 IPv6）、未知列/键、非字符串值都会拒绝整份文件，错误只给出条目序号与字段名，不回显内容。
- 顺带：设备清单表头“厂商”一列实际显示平台键，未改动（留作后续）。

验证：`GOWORK=off go test -skip TestInteractiveDeclinedOptionalEnvContinues ./...` PASS。用构建出的 `netman` 在临时目录以 CSV 清单运行 `inventory list` 与 `facts plan --json`，无需任何 Netdisco 设置，平台解析与计划输出正确。

## 2026-11-12 v0.8.0 发布准备

`VERSION` 定为 v0.8.0，CHANGELOG 的 Unreleased 归入 v0.8.0，新增 `docs/releases/v0.8.0.md` 并更新 README 当前版本。验证：在仅含跟踪与新增文件的干净副本上 `GOWORK=off make check` PASS（含 race、lint、govulncheck、架构、安装 worker、fuzz 与消费者检查）；工作区内 `goimports -l .` 会扫描被忽略的 `.reference/`、`.superpowers/`、`.work/` 参考目录而失败，CI 干净检出不含这些目录。

## v0.9.0 模块路径迁移

模块与全部导入迁移到 `github.com/gatework/net-connector`，同步发布归档与程序身份；命令仍为 `netman`、`tftp-archive`。发布隔离使用已发布的 go-standards v1.0.2，原工作区并行规范升级保留。发布夹具 11 项通过；完整 make check 与同提交远端 CI 为发布门禁，发布资产须复用 CI 产物并下载回验。
