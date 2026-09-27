# 本地实施最终核对

2026-09-27，macOS arm64 / Apple M5 / Ruby 4.0.6 / Bundler 4.0.20。
基于最初的 dirty 工作树增量修改；HEAD 仍为 v0.4.1 的
`3192377190fa8b28334e1f39007789ef2ae5cc6e`。原有 VERSION 0.4.2 改动保留，
本任务没有改版本、提交、暂存、推送、创建远端 PR 或发布。

## 任务状态

| 工作包 | 当前本地状态 | 证据 / 边界 |
| --- | --- | --- |
| NC-00 | completed | 初始 288 / 2267、dirty 状态、依赖和工具保存在 NC-00-baseline.json |
| NC-01 | completed | 默认配置输出敏感；日志/错误不含正文，原 Result/备份保留字节；正式 expect-pty 0.5.0 公共 Redactor，连接器只保留作用域/策略 |
| NC-02、NC-05 | completed | 清单流式/累计预算及总期限；批内非敏感设置快照、动态凭据与入口预检；NC-02-05-verification.json |
| NC-03、NC-04 | completed | 采集前路径锁、同 FD 读取、目录同步及提交后错误回执；跨进程/故障注入，NC-03-04-verification.json |
| NC-06 | completed with capability restricted | 即时生效设备先读回后保存，完整步骤和原租约保留；PAN-OS 缺少隔离证据时自动改写被明确拒绝，NC-06-verification.json |
| NC-07A/B | completed | 纯预检、源探测至上传的业务租约、设备报告回执及完成后失败；旧三成员 TftpBackup 不变，NC-07-verification.json |
| NC-07C | deferred, optional | 没有服务端适配器或可靠的时间/版本归属协议；执行路径不生成 server_verified，不允许串行覆盖固定名来扩大集合 |
| NC-08 | completed | 默认 strict/schema 1 保持；selected/schema 2 显式启用，受控诊断与单调时间；NC-08-verification.json |
| NC-09、NC-10 | completed | 每批一次旧命名索引及失效核对；按需 TextFSM 和严格 UTF-8；缺少其他编码样本，source_encoding 条件扩展 deferred；NC-09-10-verification.json |
| NC-11 | completed | 23 个默认基准、2 个预算样本及原始计时；可选累计预算保留完成步骤，不宣称等工作量内存降幅；NC-11-verification.json |
| NC-12 | deferred, optional | 未新增协作取消/整批 deadline。现有后创建线程先中断、创建失败 kill/join/ensure 回归保留；任意回调无硬期限保证 |
| NC-13 | completed in local scope | 机器覆盖率报告、同环境 NC-00 ratchet、关键依赖最低/正常通道、安装白名单；远端矩阵未运行 |
| NC-14 | completed in synthetic scope | 共用策略矩阵、完整/部分/错误输出、视图转换和真实本地 PTY；test/fixtures/README.md 明确来源及 unknown 固件范围 |
| NC-15 | completed | architecture 的公开业务契约、stale_plan 直接抛错、三层确认和迁移说明；Unreleased 记录适用改动，未改变 VERSION |

可选扩展按任务书的后置范围单列，本轮不引入第二套调度或存储验证框架。
这里的 completed 只对应已获授权的本地实现/模拟验收，不表示生产设备、远端 CI 或发布完成。

## 当前验证

- `bundle exec rake ci`：442 tests / 4758 assertions，0 failures/errors/skips；160 文件 lint、
  workflow lint、源码/完整历史/gem 扫描、9 个基准 smoke、120 文件包和两种隔离安装均通过。
- `BUNDLE_GEMFILE=gemfiles/minimum.gemfile bundle install --local`：退出 0。
- `BUNDLE_GEMFILE=gemfiles/minimum.gemfile bundle exec rake test package:verify`：442 / 4758，
  全部通过；最小消费者用已发布的 expect-pty 0.5.0 与 textfsm 0.2.0，两次构建字节相同。
- 主进程覆盖率：86/99 文件，3788/3916 行（96.73%），1260/1498 分支（84.11%）；
  未加载的 13 文件单列，不计为已覆盖；同运行时 NC-00 ratchet 通过。
- 正式 expect 0.5.0 安装缓存及 Redactor 源码 SHA 与已核验官方包一致，运行时流对象
  确认为 Expect::Redactor；未使用历史本地补丁包装脚本。

准确命令、日志、摘要及工作树核对见 [NC-13-15-verification.json](NC-13-15-verification.json)。
此前的每批证据和归档继续保留，不用当前包替换旧包；文档历史段落中的“待继续”表示当时进度。

## 未验证与后续条件

| 范围 | 状态及具体原因 |
| --- | --- |
| GitHub Actions 的 Ubuntu/macOS 多 Ruby 矩阵 | BLOCKED for this delivery：用户仅授权本地验证，未推送或触发远端运行；仅校验工作流并在本机运行对应命令 |
| 真实 SSH/Telnet、设备权限、固件、保存/commit、TFTP 服务器 | BLOCKED for this delivery：本轮只允许模拟传输、本地 PTY/HTTP 和合成数据；没有现场验收证据 |
| PAN-OS 候选变更归属与 commit 完成 | BLOCKED：没有目标固件隔离/锁和提交实验；当前 API 拒绝自动改写，而非输出虚假已确认结果 |
| 服务端文件、时间/版本及摘要归属 | deferred NC-07C；device_reported 不表示服务器验证，也不隔离外部同名任务 |
| 非合作回调硬期限、整批取消 | deferred NC-12；现有单命令/清单期限不能冒称覆盖任意回调和整批工作 |
| 网络文件系统与断电恢复 | 未执行：本地故障注入只验证调用和回执分支，不证明实际存储设备的耐久性 |

跨设备会话修改、未合作的文件写入、外部 TFTP 同名任务不在本地租约保护内。
任何超时/预算/收尾错误都不证明设备命令未执行；已知产物保留，禁止自动重放或回滚。
