# Interfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将单设备接口业务组织为 `device.interfaces` 集合对象，完整迁移真实调用方并验证安全边界。

**Architecture:** 直接迁移现有 Topology 协调对象和领域值对象为 Interfaces；设备只提供资源访问器。厂商策略和批量调度保留各自职责，批量执行统一消费新的单设备 API。

**Tech Stack:** Ruby >= 3.2、Minitest、现有 TextFSM 与 expect-pty。

**Spec:** `docs/superpowers/specs/2026-10-19-interfaces-design.md`

## Global Constraints

- Ruby >= 3.2；不新增依赖；解释性源码注释使用中文，遵循 CONTRIBUTING。
- 在当前未发布工作区增量修改；不回滚其他改动、不提交、不发布、不连接真实设备。
- 资源对象不缓存现场证据，不拥有会话；保留现有确认、重验、结果与清理契约。
- 多设备入口保持 `Operation::Batch` 返回值；能力键与厂商档案字段保持既有语义。

## Review Focus

- 重复使用同一接口对象时设备事实变化：新规划须重读、旧计划须拒绝。
- plan 的格式选项非法或回调失败：设备 I/O 前校验选项，失败后释放租约。
- plan 采集间隙另一个线程/Fiber 尝试写入：必须拒绝，sync 在已有租约内正常完成计划构造。
- CLI 与批量执行器注入连接器：只有 interfaces API 也能完成原有流程和回执。
- 独立 require、打包资源和文档迁移：新入口可加载，不残留活跃旧单设备入口。

## Task 1: 单设备接口集合与生命周期

**Files:** `lib/net/connector/device/interfaces.rb`、`device/interfaces/*.rb`、`device/base.rb`、厂商引用；`test/interfaces_test.rb`、现有拓扑测试。

**Interfaces:** 产生 `device.interfaces`，支持 neighbors/descriptions/plan/audit/apply/sync；领域类型位于 `Net::Connector::Interfaces`。

- [x] 补消费者行为测试：获取对象无 I/O、同对象重读与陈旧计划拒绝、plan 校验和租约隔离、失败释放与 sync 计划构造。
- [x] 运行新测试，确认在缺失接口对象或边界时失败。
- [x] 迁移原协调对象和类型，提供资源入口，统一格式预检并覆盖 plan 租约；迁移单设备调用测试。
- [x] 运行接口/拓扑/厂商/模块加载测试，确认变更、读回、保存和错误语义。

## Task 2: 批量、CLI、文档与交付

**Files:** `netdisco/operation.rb`、`netdisco/cli/topology.rb`、相关批量和 CLI 测试、`docs/usage*.md`、`docs/architecture.md`、`RENAMES.md`、`CHANGELOG.md`。

**Interfaces:** 批量与 CLI 消费 `connector.interfaces.*`，外部批次方法和返回结构不变。

- [x] 迁移受控测试连接器，只提供 interfaces 资源方法；运行批量与 CLI 测试观察旧调用路径失败。
- [x] 更新生产调用、独立加载检查与双语示例；标明单设备破坏性迁移和返回值。
- [x] 运行 `bundle exec rake lint test benchmark:smoke` 与打包检查，记录实测结果。
- [x] 根据改动前文件快照作独立审查，处理重要问题；最终列明实现、验证、破坏性迁移和未验证范围。

## Execution Ledger

- 设计依据：用户明确授权优雅设计并实现，随后选择单设备接口集合；常规实现选择在此记录后直接执行。
- 工作区：已有未发布迁移，原地增量实现；改动前 391 个文件已复制到工作区外快照以独立核对本次差异。
- 原深度审查中的 prepare_command、取消回执和 PTY 性能问题不属于接口资源迁移，保留为审查后续项。
- 设计检查：独立 builder check 返回 nothing important left。
- Task 1：新行为测试先出现 7 个预期失败，再通过 7 runs / 55 assertions；sync 复用私有 build_plan，避免重入 Session 明确禁止的 operation 租约。保持现有锁规则，不放宽会话重入。
- Task 2：边界假连接器改为只提供 interfaces API 后，批量测试出现 2 个预期失败；迁移生产调用后，接口、拓扑、厂商、CLI 与批量相关测试 178 runs / 2060 assertions 通过。
- 全量验证：Ruby 4.0.7 / macOS；lint 286 files 无违规；1140 runs / 12081 assertions，无失败、错误或跳过；行覆盖率 97.15%、分支覆盖率 84.74%，三个关键门槛通过；9 个 benchmark smoke 完成。测试仍有原有方法重定义与 TextFSM 正则警告。
- 打包验证：195 文件的 gem 白名单、字节一致性与秘密扫描通过，普通和 Bundler 隔离安装下的本地 PTY、厂商、模板与 CLI 烟测通过。
- Final review：独立审查本次 57 文件增量，未发现 Critical / Important 或已确认的 Minor 功能问题。额外验证不同 Fiber 的采集间隙写入拒绝、RuntimeError 回调后的租约释放、邻居变化重读及旧计划拒绝、12 个独立 require 入口。
- Final: Ruling: 既有 prepare_command、取消回执和 PTY 性能问题保持为审查后续项；本次接口对象迁移不改动这些执行边界。风险是原问题仍可能触发，不能宣称已修复。
- Final: Ruling: 验证只覆盖本机 Ruby 和合成传输；真实设备、固件、持久化介质与 expect-pty 间歇故障未验证或未定位。风险是现场行为仍须另行验证。
- Final: Ruling: 空计划 apply 保持无写入直接成功；陈旧证据拒绝的保证针对包含变更的计划。风险是空计划成功不证明当前描述仍一致，也不证明先前配置已保存。
- Final: Ruling: 会话租约只协调当前设备对象；其他设备会话和人工改动由应用时证据重验处理，不能承诺跨会话隔离。风险是读回后仍可能被外部改写。
- Final: Ruling: 按当前未发布迁移约定删除旧单设备 API；仓库内调用已迁移，仓库外消费者未修改。风险是外部直接调用旧方法、常量或路径者需要按 RENAMES 更新。
- Final: Ruling: 集合绑定创建时的厂商策略；第三方有状态策略、运行时更换 profile、Fleet 资源对象与单端口 API 不扩展。风险是有额外动态策略假设的外部扩展需要单独评估。
- Deferred minors: none。
