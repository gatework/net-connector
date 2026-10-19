# Connection Reliability Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development; implement each repair inline and obtain one independent final review.

**Goal:** 修复此前已复现的钩子返回类型、取消回执交接和 PTY 缓冲复制问题。

**Architecture:** 沿用现有 ScriptError、Thread.handle_interrupt 和 PTY 适配边界。expect-pty 添加只读标量 API，net-connector 直接使用当前公开接口。

**Tech Stack:** Ruby >= 3.4，Minitest；expect-pty >= 0.9.4。

## Global Constraints

- 现有工作区与接口集合迁移保留；不提交、安装到全局或发布 gem，不连接真实设备。
- 钩子只接受 Command/nil，拒绝必须发生在替代命令 I/O 前；错误不包含非法返回值。
- 异步取消仍可打断阻塞 I/O；已返回的完成回执先固定，原始取消随后传播。
- buffer 返回防御性副本；buffer_bytesize 返回当前未消费主缓冲的字节数，不读 I/O、不改变缓冲。
- 按用户最新要求不兼容旧 expect-pty；通过两仓库源码集成及本地 0.9.4 构建包验证，不能误把已安装 0.9.3 当作修改后的实现。

## Tasks

- [x] 1. prepare_command：先回归非法 String/false/对象和部分完成结果，再加 Command/nil 边界；合法替换与 nil 跳过保持有效。
- [x] 2. CLI 取消：在完成 apply 返回交接处确定性注入取消，断言 summary 保留 applied/steps；同时验证阻塞应用仍可取消并关闭资源，然后保护结果赋值。
- [x] 3. PTY：先验证接收、裁剪、匹配消费、EOF 与显式清空后的字节数；实现 getter、YARD/RBS/API 文档。适配器回归无快照、真实超限与关闭日志的行为；做实际本地 PTY 性能对照。
- [x] 4. 两仓库完整测试、lint/API、打包与源码依赖集成；检查受支持的最低依赖路径，独立审查本次增量。
- [x] 5. 最新接口收敛：移除 PTY 和 SSH 归档认证的旧构造、日志与读取接口分支，移除旧 Redactor 能力探测；版本下界、Ruby 版本、CI、文档同步调整。

## Review Focus

- 非法钩子值不能导致发送，之前完成的命令与来源信息不能丢失。
- 同步故障与待交付取消并存时，原始故障或已知完成事实必须保持明确。
- 超限检查不依赖是否启用日志，所有受支持的依赖版本均须提供当前接口。
- bytesize 必须统计字节而非字符，消费/裁剪/EOF 后实时反映主缓冲。
- 新接口未发布前使用本地 0.9.4 包，报告明确实际加载来源和发布状态。

## Execution Ledger

- 用户“继续”承接上一轮列出的三项 P2 修复方向；根因与临时对照实验已有证据，本轮补为正式回归并落地。
- 工作区基线：两个项目当前文件已复制到工作区外独立快照，用于只审查本轮增量。
- Ruling: 用户随后明确“expect-pty 使用最新版，不考虑老接口兼容性”，撤销初版兼容分支 — 直接要求当前接口，并同步 Ruby 3.4 下界 — 旧运行环境须升级。
- Ruling: 新增 API 不能继续冒用已发布的 0.9.3 元数据，准备本地 0.9.4 并要求 `>= 0.9.4` — 防止依赖解析成功但运行缺方法 — 下游公开安装需先发布此版本；本轮不发布。
- Task 1: RED 为非法值已发送；修复后关联用例 82 runs / 1154 assertions 通过。
- Task 2: RED 为完成值和同步失败均退化成 interrupted；修复后关联用例 38 runs / 288 assertions 通过。
- Task 3: expect 计数用例 8 / 116、传输预算用例及全部源码集成通过；新旧相同 expect 缓冲实现、本地真实 PTY、输入 1 MiB、每档 3 次的写入阶段中位数：输出 4 MiB 为 0.391 → 0.082 秒，8 MiB 为 1.205 → 0.116 秒，16 MiB 为 4.456 → 0.184 秒。最终快速路径已按直接调用新接口复测。逐次验证全部输入和输出字节；这是合成本地负载，不是设备延迟预测。
- 初版独立复核未发现问题，额外验证非法对象的 inspect/to_s 均抛错及原命令敏感标记，拒绝发送并保持脱敏；用户更改兼容要求后的最终增量另行复核。
- Task 5: 新读取契约先复现误调用 expect_result，直接调用 expect 后传输、认证、脱敏回归 60 / 483 通过。
- 最终代码检查：本地 macOS / Ruby 4.0.7；expect-pty 0.9.4 `script/ci` 622 runs / 10223 assertions，102 文件 lint、API/RBS、7 组基准冒烟及普通/Bundler 隔离安装通过。
- net-connector 以临时独立 GEM_HOME 中安装的本次 expect-pty 0.9.4 包运行完整 `rake ci`：1148 runs / 12158 assertions，288 文件 lint、工作流 lint、覆盖率门槛、源码/历史/包扫描、9 组基准冒烟、195 文件包及普通/Bundler 隔离安装通过；不是默认已安装的 0.9.3。
- 受支持的最低依赖组合 expect-pty 0.9.4 / textfsm 0.2.0 / JSON 2 的重点回归 66 runs / 553 assertions 通过；未运行远端平台矩阵或 Ruby 3.4 解释器。
- 最终独立复核没有代码问题；P3 为中英文使用指南残留旧运行要求及“依赖无版本约束”的文字，已一并修正，并重建包验证。
- 最终产物：expect-pty `tmp/ci/expect-pty-0.9.4.gem`，net-connector `tmp/ci/net-connector-0.14.1.gem`；只在临时 GEM_HOME 验证，未全局安装、提交、推送或发布。旧的短进程间歇失败本轮未复现，未将其标为已修复。
