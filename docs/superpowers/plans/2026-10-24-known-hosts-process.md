# KnownHosts Process Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复继承的 SSH 信任快照被子进程提交或删除，以及关闭失败后丢失资源所有者的问题。

**Architecture:** KnownHosts 记录创建进程并拥有快照；Ssh 保留尚未关闭的 KnownHosts。沿用现有取消保护、错误优先级及原子提交。

**Tech Stack:** Ruby 3.4+、Minitest、真实 fork/本地 PTY、Tempfile、OpenSSH ssh-keygen。

**Spec:** `docs/superpowers/specs/2026-10-24-known-hosts-process.md`

## Global Constraints

- lib 方法注释中文、业务字面量英文；不批量翻译测试或说明。
- 不新增框架、公开方法或兼容入口；保留 WIP；不提交、推送或发布。
- 本地 fork/PTY 不代表远程 SSH 或实机；各验证层分开记录。

## Review Focus

- 子进程没有新增 key 时也不得 commit；Task 1 包含空增量分支。
- 子进程重复 close 不删除 `.old`；Task 1 保留两类文件并验证父进程后续提交。
- child close 后的 commit 仍拒绝；Task 1 覆盖顺序变化。
- 关闭既有故障和延迟取消保持优先级；Task 1 重跑现有取消与首故障测试。
- SSH 重开重试尚未关闭的信任文件；Task 1 注入一次真实文件关闭故障并检查文件与描述符回收。

### Task 1: Enforce ownership and retain failed cleanup

**Files:** 修改 `lib/net/connector/engine/known_hosts.rb`、`lib/net/connector/engine/transports.rb`、`lib/net/connector/engine/error/metadata.rb`、`test/known_hosts_test.rb`；迁移 `test/transport_test.rb` 中遗失资源后不重试的旧断言，`test/module_loading_test.rb` 改用实际构造器建立合法所有者。

**Interfaces:** 消费既有 `KnownHosts#initialize/commit/close/path`、`Ssh#open/authenticated/close`；公开签名不变；新增受控错误码 `known_hosts_inherited`。

- [x] 增加真实 fork 回归：child close 保留 parent snapshot/.old；child commit（空增量、有增量及关闭后）拒绝且共享信任不变；child 重开获得独立快照、可提交，parent 仍可读写和提交。增加 close 失败后由 Ssh 重开的重试回归。
- [x] Run: `bundle exec ruby -Itest test/known_hosts_test.rb`。Expected: 新回归失败，既有 17 项通过；记录 RED。
- [x] 在创建时登记 PID，commit 提前拒绝继承对象，close 区分描述符与文件删除所有权；仅在清理成功后释放 KnownHosts 和 Ssh 的清理引用，保留首故障规则。把新错误码加入安全诊断词表。
- [x] Run: `bundle exec ruby -Itest test/known_hosts_test.rb`。Expected: 全通过，包括既有取消、锁与替换场景。
- [x] Run: `bundle exec rake`。Expected: lint、完整测试、覆盖率通过；记录实际数目。

### Task 2: Document and verify delivery

**Files:** 修改 `CHANGELOG.md`、`docs/architecture.md`；证据写入 `.ctx-known-hosts-audit-20261023`。

**Interfaces:** 消费 Task 1 的所有权契约和错误码，不修改公开接口。

- [x] 记录进程所有权、子进程重开和关闭重试行为；哈希保护回写本次文件到实际 checkout。
- [x] Run: `bash script/ci`（实际 checkout）。Expected: 全部门禁通过，保留候选制品。
- [x] 对候选全部打包文件进行字节核对；普通和 Bundler 隔离安装执行继承关闭/提交/重开探针。Expected: 依赖路径明确、fork 探针及安装均退出 0。
- [x] 完成一次独立审查；处理实质问题并验证，保留报告。额度故障如再次发生，记录未完成，不用作者自查替代。
- [x] 核对本次范围与初始 WIP，更新逐项验收报告；整体八模块目标仍须另做完成审计。
