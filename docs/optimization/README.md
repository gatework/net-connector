# v0.4.1 优化计划实施记录

任务书：`net-connector-v0.4.1-codex-optimization.md`（2026-09-27）。
原始文件的 SHA-256、工具版本和完整依赖解析结果见 [NC-00-baseline.json](NC-00-baseline.json)。
这些记录属于开发验收材料，不进入 gem；没有扩大 gemspec 白名单。

当前本地实施已收口：NC-00 至 NC-11（含 NC-07A/B）、NC-13、NC-14、NC-15 的适用工作已完成；任务书列为后置可选的 NC-07C、NC-12 明确 deferred。最新状态、当前验收及现场边界见 [FINAL-AUDIT.md](FINAL-AUDIT.md)。共享 Redactor 使用正式 expect-pty 0.5.0；下文各批记录及其中的待办描述仅代表当时状态，历史验收包没有被后续产物覆盖。

## 共享脱敏正式依赖验收：expect-pty 0.5.0

2026-09-27 再次读取 RubyGems 元数据并下载正式包，确认 0.5.0 已于
`2026-09-27T06:38:28.944Z` 发布，公开 `Expect::Redactor.redact`、
`replacement:`、`patterns=` 和 `finish(partial:)`。
下载包、Bundler 安装缓存的 SHA-256 均为
`3f132008607c12122650b80cb3562c14ae52b55c22bbd074d25dbf14c63f80cf`，
实际加载的 Redactor 源码与正式包一致。完整文本与分块流探针均通过。

gemspec 改为 `expect-pty ~> 0.5.0`，忽略的本地 lockfile 通过
`bundle update expect-pty --conservative` 更新，其他依赖版本未变。
连接器继续复用共享字节过滤器，只保留作用域及输出敏感性策略；本次未改 expect
仓库，也没有修改 VERSION、提交或发布。旧补丁包和包装脚本仅保留作历史证据。
当前命令恢复为：

```sh
bundle install
bundle exec rake ci
```

本地 Ruby 4.0.6 / macOS arm64 上，脱敏、输出隐私、真实本地 PTY 和模块加载
定向回归通过：**56 runs / 875 assertions，0 failures/errors/skips**。
完整 `bundle exec rake ci` 退出 0：**404 runs / 4390 assertions，0 failures/errors/skips**；
151 个 Ruby 文件 lint、workflow lint、源码/历史/gem 扫描、构建，以及使用正式
expect-pty 0.5.0 的普通和最小 Bundler 隔离安装均通过。
当前源码、依赖来源、日志与新归档摘要见
[NC-01-published-dependency-verification.json](NC-01-published-dependency-verification.json)。
这一验收关闭共享接口的发布依赖缺口；整份优化计划仍在进行中。

## 批次 A：NC-00、NC-01

按照任务书 0.2 的默认批次，先建立基线并修补配置输出隐私。
NC-02 至 NC-14 的其他工作仍按依赖顺序推进，本批次不代表整个计划完成。
NC-15 的隐私迁移说明随本批次更新，其余契约说明仍 deferred。
用户随后明确要求复用 expect-pty 的实现，并授权联动两个仓库、仅做本地验证。
以下初始基线及补丁联调保留为历史证据；当前验收使用上方记录的正式 0.5.0 依赖包。

### NC-00 基线

| 项目 | 初始状态 |
| --- | --- |
| HEAD / `v0.4.1^{commit}` | 均为 `3192377190fa8b28334e1f39007789ef2ae5cc6e` |
| Git | `main`，非浅克隆，有完整本地 Git 元数据 |
| 原有工作树 | 35 个已跟踪文件有修改，另有 5 个未跟踪文件；无暂存修改 |
| 原有版本文件 | 工作区已为 `0.4.2`，与标签 `0.4.1` 不同；本批次未改 VERSION |
| 环境 | Ruby 4.0.6，Bundler 4.0.20，Darwin 25.6.0 / arm64 |
| 关键依赖 | expect-pty 0.3.1、textfsm 0.2.0、minitest 5.27.0、rake 13.4.2、rubocop 1.91.0 |
| 初始测试 | 288 runs、2267 assertions，0 failures/errors/skips |
| 初始覆盖率 | 已加载 78/91；行 2969/3091；分支 890/1103 |
| 初始完整 CI | 退出 0；源码及历史扫描、Ruby/workflow lint、测试、gem 扫描、两种隔离安装通过 |

这里的测试基线是**初始 dirty 工作树**，不是声称纯标签源码得到相同计数。
原有修改包括覆盖率门槛、引擎/批处理整理、厂商能力、文档及版本调整；均予以保留。
初始差异和状态另外保存在忽略目录 `tmp/nc-optimization/initial-worktree.patch`
及 `initial-status.txt`，没有 reset、clean、stash 或覆盖原有未提交内容。
依赖使用现有 Gemfile/gemspec 执行 `bundle install`，未执行升级或改变 lockfile 政策。

初始命令（退出码均为 0）：`ruby -v`、`bundle --version`、`uname -a`、
`git status --short`、`git rev-parse HEAD`、`git rev-parse 'v0.4.1^{commit}'`、
`git rev-parse --is-shallow-repository`、`bundle install`、`bundle list`、
`bundle exec rake test`、`bundle exec rake ci`。
全量输出分别留在 `tmp/nc-optimization/baseline-test.log` 与 `baseline-ci.log`。
机器摘要列出未加载的 13 个文件，没有将它们记为已覆盖。

### 所有工作包的初始核对

下表的状态使用任务书约定，表示实施前的代码核对；“本批结果”单独列出。
路径均相对仓库根目录，符号比易变化的行号更适合作为后续实施入口。

| 工作包 | 初始分类 | 现有符号与证据 | 本批结果 / 后续依赖 |
| --- | --- | --- | --- |
| NC-00 | open | `Rakefile#test/ci`、`script/coverage_report.rb#passed?`；此前没有本任务现场基线 | completed，本节及 JSON 保存实际结果 |
| NC-01 | open | `engine/command.rb#initialize` 无输出标记；`device/running_config.rb#call` 使用普通命令；`Base#perform_script` 在命令范围外清理 | 本地隐私矩阵及正式 expect-pty 0.5.0 依赖验收均通过 |
| NC-02 | open | `netdisco/client.rb#default_request` 完整获取 body；`#devices/#legacy_devices` 无累计字节、数量和总期限 | 批次 B 实施，见下方资源预算验收 |
| NC-03 | open | `operations/local_backup.rb#call` 先采集，无路径锁；`SavedConfig#find/#export` 检查与读取分离 | 批次 C 实施，本地跨进程/别名/安全读取验证通过 |
| NC-04 | open | `operations/private_file.rb#write` 文件 fsync 后 rename，无目录同步及提交回执 | 批次 C 实施，故障注入与最小部分成功契约通过；未做断电实验 |
| NC-05 | open | `netdisco/settings.rb#initialize` 保留 env 引用；`#credentials_for` 同时读取策略；`#public_config` 未完整校验枚举 | 批次 B 实施，见下方策略快照验收 |
| NC-06 | open | `operations/topology.rb#apply_plan` 把 `finish_commands` 放在读回之前；`vendor/*/topology.rb` 保存/commit 仍未分阶段 | 批次 D 实施，先读回后保存；PAN-OS 候选隔离未验证时关闭自动改写 |
| NC-07A | open | `operations/tftp_backup.rb#call` 在源探测后才构造策略脚本；无覆盖全部业务的租约；日志后才构造回执 | 批次 E 实施，原生纯预检、整次租约及完成后错误回执通过 |
| NC-07B | open | `TftpBackup = Data.define(:server, :path, :completed_at)` 无来源/格式/核验等级 | 批次 E 新增组合式 TftpReceipt；旧对象成员与构造保持 |
| NC-07C | open | `Operations::TftpBackup#call` 没有调用方服务端核验适配器 | deferred，可选扩展；默认仍仅设备报告 |
| NC-08 | open | `netdisco/batch.rb#success?/#summary` 只有 strict 语义，时间差使用墙钟；`Fleet#run_one` 已区分关闭失败的部分成功 | 批次 C/E/F 完成受控回执、显式 selected/v2、诊断白名单及单调计时；默认 Data/JSON/strict 保持 |
| NC-09 | needs_reproduction | `operations/saved_config.rb#find` 缺规范文件时逐次 `Dir.children`；`Fleet#backup_one` 每设备调用 | 批次 G 将 8 台设备的扫描从 8 次降至 1 次；规范全命中为零，快照与安全读取测试通过 |
| NC-10 | open / needs_reproduction | `SavedConfig` 顶层 require `parse_output`，后者加载 TextFSM；`ParseOutput#call` 仅 force_encoding | 批次 G 完成独立进程惰性加载和严格 UTF-8；复现了非法字节重写及拓扑裸编码异常，未声称 TextFSM 必然抛错 |
| NC-11 | needs_reproduction | `engine/execution.rb#execute` 保留所有步骤；`Result#output` join；`ResponseReader` 只有单响应上限 | 内存基准及累计预算 deferred，不宣称已测性能提升 |
| NC-12 | open | `netdisco/worker.rb#run` 有异常 kill/join 兜底，无协作取消/批次期限 | deferred，后置可选；异常清理不是新缺陷 |
| NC-13 | open | `script/coverage_report.rb` 的 80% 分组门槛、未加载清单已在原有修改中；无按模块 ratchet 或依赖兼容通道 | 原有门槛部分为 already_fixed；本次保存静态基线，其他项 deferred |
| NC-14 | needs_reproduction | `test/{collection_contract,collection_prompt,tftp_evidence,topology,textfsm,transport}_test.rb` 已有合成契约 | 已增加隐私、拓扑和 TFTP 合成夹具、PTY 检查和来源；PAN-OS commit 实验 blocked |
| NC-15 | open | `README.md`、`docs/architecture.md`、`docs/VERIFICATION.md`、`CHANGELOG.md` | 已记录 NC-01 至 NC-08 本地实现的边界及迁移；后续任务及最终全契约核对仍 deferred |

表中 `engine/`、`device/`、`operations/`、`netdisco/`、`vendor/` 的完整前缀均为
`lib/net/connector/`。已存在的局部保障不等于整个工作包已完成。

### NC-01 复现与实现

改实现前先加入 `test/output_sensitive_test.rb`：首次 15 个测试产生 10 failures、
5 errors，退出 1。失败包括未登记配置秘密出现在外部/debug/raw 日志、超时错误
output、清理错误 underlying.message/backtrace；新字段尚不存在也被明确检出。
原始复现日志在 `tmp/nc-optimization/nc01-before.log`，只含运行时生成的假秘密。
这证明模拟条件下的诊断泄露，不表示已经发生生产事故。

| 文件 | 本批改动 | 兼容性 |
| --- | --- | --- |
| `lib/net/connector/engine/command.rb` | 独立 output_sensitive 标记；with_text 保留；采集复制方法 | 旧默认和 sensitive 行为保留 |
| `lib/net/connector/engine/errors.rb` | 仅维护临时词表与输出敏感性，字节过滤委托 Expect::Redactor | 不将配置正文加入长期词表；依赖公共接口 |
| `lib/net/connector/engine/session.rb` | 响应日志暂停、追加查询继承、错误屏蔽及清理范围 | 锁、错误类型/阶段、单响应预算和不重放策略保留 |
| `lib/net/connector/engine/log.rb` | 外部 logger 同样拒绝敏感正文；日志器异常保留安全类型 | 不关闭或修改外部 logger |
| `lib/net/connector/device/{base,running_config}.rb` | 所有厂商采集标记，保护准备/最终清理 | 保留 execute_operation 签名和厂商旧钩子 |
| `test/output_sensitive_test.rb`、`test/transport_test.rb` | 合成隐私矩阵及真实本地 PTY | 不使用真实设备与凭据 |
| `script/smoke.rb` | 隔离安装后检查标记、PTY 配置隐私及普通日志恢复 | 普通 gem 与最小 Bundler 应用均覆盖 |
| README、architecture、VERIFICATION、Unreleased | 默认值变化与诊断/业务数据边界 | VERSION 未在本批次改动 |

新增矩阵同时断言日志与错误不含秘密、返回配置及备份 SHA 不变、后续普通命令
仍保留诊断。PAN-OS 候选差异、全部 8 个内置厂商标识、钩子追加查询、新建命令
替换原命令、异常 cause/full_message、非局部退出和重连均有对应场景。
本地 PTY 验证 raw/text 记录器暂停、超时关闭与 waitpid 确认子进程已回收。

### 共享脱敏接口联调

本节保留 0.4.0 阶段的历史过程；当前使用已发布的 0.5.0，见文档开头。

RubyGems 0.4.0 已在本轮工作期间发布。直接下载的官方包 SHA-256 为
`dd2788f7608c49c0e5c2e6311990febf6a6f7888cdab80db2587d3909fe554e9`；
实际解包确认 `Expect::Redactor` 仍由 `private_constant` 声明，仅支持内部
`append`/`finish`，没有完整文本入口或自定义替换标记。初次注册端查询曾返回
0.3.3/404，后续已重新读取并以下载包为准，不再将旧查询当当前状态。

expect 仓库以 `5a219f737c988ec262669171475d42e6ee6c97ef` 为联调基线，保留
其原有 8 个未提交文档/工作流/示例改动。本轮只增加公共接口、独立接口测试、
接口文档/Unreleased 及隔离安装断言，没有改两个仓库的 VERSION，也未提交或发布。
最初非交互 shell 选到系统 Ruby 2.6 导致 Bundler 不匹配；已在该仓库使用
`zsh -ic` 修复实际命令环境，基线为 319 runs / 1820 assertions，退出 0。

expect 中新增 `Expect::Redactor.redact` 完整文本入口、`replacement:` 参数、
空模式支持、输入复制/校验及 `finish(partial:)`。原有流算法被复用，默认流
行为保留。net-connector 删除重复匹配/缓冲代码，保留 `[REDACTED]` 标记、
敏感范围及现有完整词收尾契约；旧分片/重叠/标记测试保留断言，仅改用共享流驱动。

本地补丁包安装在 `tmp/nc-dependency-gems/`，没有覆盖系统安装或 RubyGems 包。
`tmp/nc-optimization/with_local_expect.rb` 只设置该次命令的 GEM_HOME/GEM_PATH/PATH，
使用相同的 Ruby 4.0.6 / Bundler 4.0.20。当时工作区的重跑命令为：

```sh
ruby tmp/nc-optimization/with_local_expect.rb exec rake test
ruby tmp/nc-optimization/with_local_expect.rb exec rake ci
```

expect 仓库的命令为 `zsh -ic 'script/ci'`，包括全量 lint/测试、示例、基准
正确性烟测、构建和两种隔离安装。两个包名称中的 0.4.0 并不证明字节相同：
本地补丁包与官方包摘要单独记录在验收 JSON，联调后必须用真实发布包重验。
当时 gemspec 的 `~> 0.4.0` 只是本地联调范围；该发布前置条件现已由正式
0.5.0 包验收满足。能力检查拒绝私有接口，不通过
`const_get` 绕开 Ruby 私有常量，也没有回退到第二份过滤实现。

### 验证与副作用边界

运行结果及退出码见 [NC-01-verification.json](NC-01-verification.json)。
下列日志保存在忽略目录 `tmp/nc-optimization/`，可在同一工作区复查：

- `nc01-before.log`：修改前失败证据；预期退出 1。
- `nc01-test.log`：完整 `bundle exec rake test`。
- `nc01-contracts.log`：原有脱敏、引擎、配置/提示/策略、加载及拓扑互斥定向回归。
- `nc01-ci.log`：完整 `bundle exec rake ci`，含构建、扫描及隔离安装。
- `shared-redactor-tests.log` / `shared-redactor-full-test.log` / `shared-redactor-ci.log`：复用实现后的定向/全量/完整 CI。
- `expect-baseline-test.log` / `expect-redactor-before.log` / `expect-redactor-after.log` / `expect-ci.log`：依赖库基线、先失败的接口测试及回归链。

只创建了本地临时日志、备份和合成 PTY 子进程，没有连接网络设备、执行生产
保存/commit 或上传配置。库的安全扫描工具使用既有固定版本与摘要策略。
已完成步骤中的业务内容仍完整保留；诊断屏蔽不证明设备没有执行，不允许自动重放。
没有 push、远端 PR、tag 或 gem 发布；初始工作区的 `0.4.2` 只作为本地测试包版本。

各范围的当前验证边界如下：

| 范围 | 状态 | 原因 |
| --- | --- | --- |
| 真实厂商/固件、SSH/Telnet、TFTP 服务端及配置变更 | BLOCKED | 本轮限定模拟传输、本地 PTY、临时文件和合成清单；没有现场输出/授权实验 |
| GitHub Ubuntu/macOS × Ruby 3.2/3.3/3.4/4.0 远端矩阵 | BLOCKED | 未授权远端推送；本次只运行本机 macOS / Ruby 4.0.6 的完整检查链 |
| 指定 v0.4.1 ZIP 字节与 SHA-256 | 未验证 | 本地完整 Git 工作树与标签提交可核验，本轮未获取指定归档 |
| 仅使用已发布 expect-pty 的公共接口接入 | PASS（本地） | 正式 0.5.0 的 API、缓存来源、全量 CI 与两种隔离安装均已核验 |
| NC-07C、NC-11 至 NC-15 的剩余工作 | deferred | 尚未实施或尚缺专门复现/验收；不能以已完成批次测试代替 |

真实设备适配范围仍为 unknown。路径锁及文件持久性回执的本地证据见批次 C。
分阶段拓扑的本地证据见批次 D，PAN-OS 自动提交仍未启用。TFTP 服务端证据、
性能基准与协作取消等目标尚未完成，不应当作现有能力使用。成功策略与报告 schema 见批次 F。

## 批次 B：NC-02、NC-05

在原有工作树和批次 A 上继续实施，仅使用合成清单、模拟回调、本地 TCP HTTP
服务和临时目录。没有设备 I/O、生产凭据、远端推送或发布。

### 复现与边界

- NC-02 初始定向测试为 13 runs / 49 assertions / 13 errors：预算参数及稳定错误码尚不存在。
- NC-05 初始测试为 8 runs / 23 assertions / 5 failures / 2 errors：批内策略会随 ENV 变化，show-config 接受非法枚举，清单客户端被过早缓存，快照及 YAML 预算入口缺失。
- 流式故障注入又确认 Net::HTTP 的 chunked 收尾在异常展开时会继续读取。首次真实 HTTP 超额测试得到总期限错误而非字节上限；改为先关闭连接后，能立即保留原始预算错误。
- 半个 chunk 后停止发送的现场探针中，0.5 秒期限曾约 1.013 秒才返回。增加仅关闭自有 HTTP 连接的期限观察线程后约 0.503 秒返回；这两个数是单次诊断样本，不是性能保证。正式回归关闭异步 raise 路径并用 Queue 阻塞读取，证明 deadline 必须主动关闭传输；测试没有固定 sleep，并检查观察线程已 join。
- 注入的 requester 自行抛出带正文的 Client::Error 时，原错误路径会直接透传。新增测试先失败，再统一转换为不带正文及 cause 的 connection_failed；不能仅按异常基类信任回调提供的消息。

### 实现与兼容性

| 文件 / 符号 | 结果 |
| --- | --- |
| `netdisco/client.rb`、`inventory_budget.rb` | 每次清单独立预算；认证、分页、兼容查询共用单调期限、实际正文字节和去重前记录数；失败不返回部分清单 |
| `Client#default_request/#read_response` | read_body 逐块检查，不依赖 Content-Length；剩余期限传入原生超时，超额/超时关闭本次 HTTP 连接；禁用隐式 GET 重试 |
| `Client::Error#code` | 稳定的预算/协议错误码，报错无正文、API key、凭据或底层 cause；保留原 Error 类型 |
| `Client#initialize(requester:)` | 保持两个位置参数的旧回调接口；只在返回后检查资源/时间，不能限制回调内部的下载或阻塞 |
| `Settings#snapshot/#for_run/#validate!` | 冻结非敏感策略；复用 Configuration、Planner、Client 范围规则；快照不保留 ENV 或凭据解析器引用 |
| `Settings#device_credentials_for` | 逐设备读取秘密；from_file 保留动态环境来源，公开 credentials_for 入口保留 |
| `Fleet` | 在清单请求前捕获策略，按次创建默认清单客户端；执行批准计划不重抓清单；自定义 resolver 的显式连接选项保持原优先级 |
| `ConfigFile`、`CLI` | 新预算及明文 HTTP 决策支持 YAML/ENV；CLI > ENV > YAML > 默认值；非法策略在构造 Fleet 前拒绝；export 只验证离线目录 |
| `test/netdisco_budget_test.rb`、`test/netdisco_settings_test.rb` | 超额/超时/协议错误时凭据和连接工厂调用为 0；验证批内隔离、逐设备凭据轮换、新批刷新及离线入口 |
| `gemspec`、`script/smoke.rb`、README/architecture/VERIFICATION/Unreleased | 显式声明 timeout 运行依赖，隔离安装检查新预算/离线预览，记录默认值及迁移边界 |

默认上限为 16 MiB/响应、128 MiB/调用、100000 条记录、10000 页、300 秒。
这是设计起点，尚未做真实清单容量压测。HTTP 明文默认仍允许，以免静默破坏旧部署；
建议 HTTPS，显式 `allow_insecure_http: false` / `NETDISCO_ALLOW_INSECURE_HTTP=false`
可在请求前拒绝 HTTP。既有 HTTPS 证书验证未关闭。

`Settings#snapshot` 固定每次执行策略，不负责约束调用方注入的任意 client 或
credentials 回调；后者显式提供的连接选项依然有效。公开快照不含秘密，绑定
策略的 Settings 仍持有动态秘密来源，不能把整个来源对象作为报告序列化。

### 验证记录

初始失败日志为 `tmp/nc-optimization/nc02-before.log`、`nc05-before.log` 和
`nc02-chunk-deadline-before.log`。最终运行命令、计数、覆盖率、源码与产物摘要
见 [NC-02-05-verification.json](NC-02-05-verification.json)。仍使用已隔离安装
的本地 expect 公共接口补丁，不把本批测试算作官方 0.4.0 包的兼容性证明。

最终 `ruby tmp/nc-optimization/with_local_expect.rb exec rake ci` 退出 0：
338 runs / 3239 assertions，0 failures/errors/skips；138 个 Ruby 文件 lint、
workflow lint、源码/历史/安装包扫描、构建、普通和最小 Bundler 隔离安装均通过。
覆盖率为 79/92 个已加载文件、3191/3305 行、996/1213 分支；13 个未加载文件
在 JSON 中单列。本批之外的 26 个原有 net-connector 差异、expect 的 8 个原有
差异均与初始快照逐字节一致，两个仓库的 VERSION 保持本轮开始时的值。

剩余工作包继续按任务书顺序推进。本批不证明跨进程备份互斥、持久性回执、
拓扑分阶段保存、TFTP 服务端核验、结果策略或全脚本内存预算已经完成。

## 批次 C：NC-03、NC-04

本批只使用临时文件、合成采集器、线程/Fiber、独立 Ruby 子进程和本地 PTY。
复用批次 A 的 expect 公共接口补丁，不改 VERSION，不提交或发布。

### 缺口复现与实现

- NC-03 初始 11 runs / 23 assertions，6 failures、3 errors；缺路径锁和安全读取。新增 Queue 竞争证明未获锁者不采集，并用子进程握手验证跨进程互斥，不依赖固定 sleep。
- 初版摘要直接使用原始文件名；大小写/Unicode 别名测试先失败，修为归一化文件名摘要。锁对尚不存在的目标同样有效；在区分大小写的文件系统上会保守合并这些名称的所有权，不改变实际文件名。
- 同 Fiber 自动重用锁会允许递归采集覆盖，测试先失败。现在只有实际持锁的 Fleet 可授权一次内层借用，进入 LocalBackup 时即消费；其他线程/Fiber/进程及采集中的递归调用仍竞争 flock。
- NC-04 初始 11 runs / 15 assertions，9 failures、1 error；缺父目录同步及完成回执。新增故障矩阵覆盖创建、写入、flush、文件同步、rename、目录打开/同步与收尾，检查旧/新文件、0600、临时文件清理、错误正文屏蔽及 Fleet 分类。
- 外部 WriteError 子类能伪造回执/消息的测试先失败，现只接受本库定义的具体错误类型。无关异常上的 backup 字段不作完成证据，报告和 CLI 也遵循此边界。

`BackupLock` 保留稳定的私有锁 inode，释放时仅关闭 FD；校验文件类型、所有者、
单硬链接、0600 和打开后的路径身份。默认非阻塞，`lock_timeout` 为非负有限秒数。
路径锁在会话外取得；已有 `with_operation` 中调用 `backup` 会返回 SessionBusy。
`SafeFile` 将类型检查、内容或摘要读取固定在一个 NOFOLLOW/NONBLOCK FD 上；
未变内容跳过写入前再核对目录项。直接备份安全替换末级链接，Fleet/离线入口拒绝链接。

写入按“临时文件 → 文件 fsync → rename → 父目录 fsync”执行。
`PrivateFile.write` 成功仍返回原路径；内部回执区分 not_committed、committed、
durable 和阶段。替换后失败由 `BackupPersistenceError` 保留原 Backup，Fleet
按已有 saved_with_error/partial 分类；旧命名基线仍保留。报告已提交时保留位置，
导出返回错误并说明 committed。旧 Data 成员、JSON schema、strict 规则均不扩展。

### 本地验收

最终命令为 `ruby tmp/nc-optimization/with_local_expect.rb exec rake ci`，退出 0：
**368 runs / 3556 assertions，0 failures/errors/skips**；142 个 Ruby 文件 lint、
workflow lint、源码/历史/gem 安全扫描、构建、普通及最小 Bundler 隔离安装均通过。
覆盖率为 81/94 个文件、3390/3511 行、1047/1278 分支；13 个未加载文件单列。
隔离安装烟测通过实际 PTY 采集、私有备份与锁、目录同步及 SavedConfig 读取。
首次安装检查暴露两种安装模式共用烟测目录的问题，分开目录后完整 CI 重跑通过。
命令、失败复现日志、源码/包摘要与原有差异保全结果见
[NC-03-04-verification.json](NC-03-04-verification.json)。

2026-09-27 再次查询 RubyGems：最新为 expect-pty 0.4.0，元数据 SHA-256 与已下载
官方包一致，加载官方解包源码仍确认 Redactor 是私有常量。这里没有声称最新包
未发布；缺少的是本轮需要的公共接口。正式依赖接入仍需包含接口的发布包后重验。

父目录 fsync 在本机 macOS 上成功；不支持时显式返回目录同步不支持错误，EIO
等真实失败不作降级。未变文件保持 mtime，不补验历史写入。NOFOLLOW 只保护末级
路径，调用方须保护祖先目录，其他写入程序须采用同一协议。Linux/远端矩阵、
网络文件系统及真实断电恢复均未验证；本批不对这些范围标 PASS。

后续继续 NC-06/07 与相关厂商夹具，以及 NC-08 的其余结果策略、NC-09 至 NC-15。
整份优化计划仍在执行，本批完成不表示全计划验收结束。

## 批次 D：NC-06 与相关 NC-14 夹具

### 缺口复现和执行边界

`test/topology_stages_test.rb` 初始 6 runs / 83 assertions，6 failures：
读回不匹配或超时前已经发送保存命令，旧计划未包含读回序列，单独提示符被当成保存成功，
PAN-OS 未验证候选归属仍允许自动改写。另一个先失败的测试证明采集器返回未获批准的
查询步骤时也会继续保存；现执行前后均核对读回命令。原始日志为 `nc06-before.log`
和 `nc06-readback-plan-before.log`，均在 `tmp/nc-optimization/` 中。

立即生效设备由 `ImmediateStrategy` 声明退出视图、读回和保存阶段，公共 `Topology`
在原有会话租约内组织执行。目标描述不匹配、未识别接口块或读回命令变化时不保存。
保存失败/超时/无明确完成行时为 persistence_unconfirmed，底层诊断只留屏蔽后的类型。
完成步骤跨修改、读回、保存保留，保存后的失败不触发重放或自动回滚；写入前 stale_plan
继续直接抛异常。Plan 的 Data 成员和 evidence 哈希不变，commands 包含实际读回序列，
旧计划必须重新生成并审核。

PAN-OS 的候选模型不能直接套用即时生效设备的顺序。官方文档区分配置锁和提交锁，
当前没有目标固件的候选归属、隔离及 commit 完成实验。按任务书的缺证据规则，
自动描述计划/改写在 I/O 前以 candidate_isolation_unavailable 拒绝，静态能力返回 false；
只读发现及解析保留，旧纯命令构造和超时辅助方法保留，但不会用于公共自动执行入口。
没有新增锁、commit job 查询、重放或回滚命令。

### 夹具、兼容性和验收

`test/support/topology_fixture.rb` 覆盖 IOS、NX-OS、H3C、山石的进入/返回视图、修改、
读回与保存，以及各阶段超时、失败与完成文字冲突、部分解析、无完成行等分支。
来源及推断见 [夹具说明](../../test/fixtures/topology/README.md)，所有型号/实际固件为 unknown。
山石完成行来自官方文档的重启前保存示例，用于已有 save all 的判断是明确标注的推断；
未匹配现场格式返回未确认，不宣称所有固件已认证。H3C 无线使用继承策略，未增加独立现场认证。

Queue 将执行停在读回结束、保存尚未开始的间隙，验证其他线程及同线程另一个 Fiber
仍得到 SessionBusy。保存超时后另建连接只执行新的请求，修改及保存命令计数均保持 1。
已有测试替身补充 config_commands、完成步骤和保存消息；PAN-OS 原自动 commit 成功断言
按新的明确拒绝契约迁移，原有只读解析、别名、双顺序 require 及其他厂商测试继续运行。

`ruby tmp/nc-optimization/with_local_expect.rb exec rake ci` 最终退出 0：
**377 runs / 3975 assertions，0 failures/errors/skips**；145 个 Ruby 文件 lint、
workflow lint、源码/历史/gem 扫描、构建、普通和最小 Bundler 隔离安装均通过。
覆盖率为 82/95 个文件、3455/3581 行、1067/1302 分支；13 个未加载文件单列。
安装包的本地 PTY 烟测包含规划、分阶段修改/读回/保存和读回输出敏感标记。
源码、日志、归档包摘要和原有差异保全见 [NC-06-verification.json](NC-06-verification.json)。

本批仍使用 expect 的本地公共接口补丁。只做合成传输及本地 PTY；未连接真实设备，
未执行生产配置保存或 commit，未推送或发布。真实厂商/固件、设备端并发隔离、
Linux/远端 CI 矩阵、PAN-OS 候选提交实验和正式 expect 依赖接入仍未验证。
NC-07、NC-08 的剩余结果策略及 NC-09 至 NC-15 的其余工作继续推进。

## 批次 E：NC-07A/B 与相关 NC-08/14 支撑

### 复现与实现

`test/tftp_boundary_test.rb` 初次为 7 runs / 6 assertions、5 failures、2 errors：
H3C 不支持的参数仍触发源探测，探测后的间隙可被竞争调用插入，完成后日志错误
被当成普通失败，扩展回执不存在。原始日志为 `tmp/nc-optimization/nc07-before.log`。

内置策略新增纯 `validate_options!`，通用参数复制并校验后才进入设备 I/O。
源探测、上传脚本、失败优先的完成证据、路径解析、回执及事件记录共用原有会话租约。
旧扩展重写 script 时不会隐式继承父厂商新增的预检限制或配置来源声明；未提供
对应钩子时仍兼容执行，元数据为 unknown，不宣称所有厂商组合都能在 I/O 前校验。

`Base#tftp_backup_receipt` 返回不可变组合对象，旧 tftp_backup 仍返回三成员
TftpBackup。回执记录来源、格式、源文件、requested/actual 路径及 device_reported，
没有服务端摘要。H3C 自动源为启动配置，显式文件为 saved_file/unknown；山石
不指定路径时保留设备生成名且 requested_path 为 nil。显式请求不匹配返回专用错误。

看到完成证据后先生成最小回执；日志、命令/租约清理、路径和元数据钩子失败都不能
抹去上传事实。实际路径无法确认时为 nil，不冒用请求名。TftpCompletionError
只保存受控诊断及回执，Fleet 按 reported_with_error/partial 保留实际产物，拒绝
第三方 transfer 字段或子类供应完成事实。没有重传或改变 PAN-OS 固定名碰撞规则。

### 本地验收

定向命令使用 `ruby tmp/nc-optimization/with_local_expect.rb exec ruby -Ilib:test`
加载 TFTP 边界/证据、connector、capabilities 和 Netdisco reliability/plan 六组测试，
**97 runs / 825 assertions，0 failures/errors/skips**。
完整命令 `ruby tmp/nc-optimization/with_local_expect.rb exec rake ci` 退出 0：
**390 runs / 4211 assertions，0 failures/errors/skips**；148 个 Ruby 文件 lint、
workflow lint、源码/历史/gem 扫描、构建、普通及最小 Bundler 隔离安装通过。
覆盖率为 83/96 个文件、3559/3688 行、1148/1380 分支；13 个未加载文件单列。
安装后另用本地 PTY 确认回执入口、来源/格式、设备报告等级及旧 Data 成员。
日志、包与源码摘要、WIP 保全证据见 [NC-07-verification.json](NC-07-verification.json)。

按用户最新提醒重新查询 RubyGems：最新版本确为 0.4.0，发布时间为
2026-09-27T03:58:35.418Z；元数据 SHA 与已下载官方包一致。实际加载官方源码仍抛出
`private constant Expect::Redactor referenced`，所以继续使用隔离的本地公共接口补丁。
该结果确认已发布版本存在，同时区分公共接口尚未发布；没有修改 VERSION 或发布任何包。

本批未连接设备或 TFTP 服务器，夹具的型号与固件仍为 unknown；不证明服务器文件、
摘要、时间/版本归属或跨进程目标隔离。NC-07C 的可选核验适配器、NC-08 的其余策略/
schema/单调耗时，以及 NC-09 至 NC-15 剩余工作仍待继续，整份计划尚未完成。

## 批次 F：NC-08 成功策略、v2 诊断及单调计时

### 复现与实现

新增 `test/netdisco_reporting_test.rb` 最初为 8 runs / 23 assertions，
1 failure、6 errors：新策略/报告接口尚不存在，时钟无法独立测量。旧 strict
语义继续作为兼容基线，显式增强的失败证据见 `tmp/nc-optimization/nc08-before.log`。

默认 Fleet 返回 Batch、默认 summary 和 CLI JSON 键保持原样；Outcome/Batch
的成员、位置参数、deconstruct/to_h 保留。Report 组合原 Batch，显式 schema 2
才增加策略、覆盖、受控诊断和批次计时。selected 自动使用 v2，显式配 schema 1
或无效参数在清单读取前拒绝；策略不会重新规划或执行设备。

selected 必须至少有一台成功，其余只能是 filtered/sample_limit，且无部分成功、
回调或报告错误。缺少凭据、重复/无效地址、固定名冲突、未知厂商及未知状态均阻塞。
Report.success?/status 仍是旧严格判定，新结果单列 policy/policy_success。
coverage 只说明任务是否尝试，失败任务仍计入 attempted，不能推断备份成功。

Diagnostic 保存固定词表中的码、类型、阶段及匹配产物回执，不保留异常对象、
原消息、正文、调用栈、命令、source 或 line。未知码/阶段为 nil，未知类型为
StandardError；v2 重新筛选手工构造的旧结果与 callback/report 字段。普通文件
错误只能在报告写入边界提供文件阶段，不能作为设备备份完成证据。

Worker 的设备耗时改为单调时钟，包含开始回调、操作和关闭；v2 批次耗时含全部
worker/result 回调，截止于存报告前。UTC 审计时间单独保留；手工构造的旧 Outcome
无单调元数据时才回退墙钟差，并阻止负值。内部元数据由 with 保留，不追加 Data
成员。显式更换时间或错误字段会清除对应旧元数据。旧 ResultStore.write 的参数
不变：默认收到 Batch，显式 v2 收到可访问相同业务属性的 Report。

### 本地验收

定向命令使用 `ruby tmp/nc-optimization/with_local_expect.rb exec ruby -Ilib:test`
加载 reporting、Netdisco/Settings/reliability/plan、文件持久化及 TFTP 边界测试：
**98 runs / 1041 assertions，0 failures/errors/skips**。
完整 `ruby tmp/nc-optimization/with_local_expect.rb exec rake ci` 退出 0：
**404 runs / 4390 assertions，0 failures/errors/skips**；151 个 Ruby 文件 lint、
workflow lint、源码/历史/gem 扫描、构建、普通及最小 Bundler 隔离安装均通过。
覆盖率为 85/98 个文件、3675/3808 行、1212/1452 分支，13 个未加载文件单列。
安装烟测新增 selected 包装、覆盖信息与旧 Data/summary 结构检查。
源码、命令、日志、包摘要及 WIP 保全见 [NC-08-verification.json](NC-08-verification.json)。

本批原始验证使用 expect 的本地公共 Redactor 补丁；正式 0.5.0 的后续验收见文档开头。
没有真实清单/设备/TFTP 访问、远端
CI 或发布。磁盘报告是写入前快照，写入自身故障反映在返回对象和 CLI；对旧 Batch
重新创建 v2 视图不会补出未测量的批次总耗时或报告写入阶段。NC-07C 的可选核验、
NC-09 至 NC-15 的剩余工作仍待继续，整份计划保持进行中。

## 批次 G：NC-09、NC-10

本批以正式 expect-pty 0.5.0 为依赖，使用普通 `bundle exec`。没有调用旧本地补丁包装脚本。

### 复现与行为

`nc09-before.log` 记录 8 台设备、4 个 worker 的旧命名迁移扫描实际为 8 次。
新增批次索引后相同场景为 1 次，规范文件全命中为 0 次；没有据此推断墙钟耗时。
`nc10-before.log` 记录 11 runs / 108 assertions、5 failures，分别证明非解析入口
提前加载 TextFSM、非法字节被转义/擦除后继续解析、终端编辑损坏 UTF-8，以及
拓扑原文校验抛出裸 ArgumentError。先前独立 ParseOutput 探针没有复现“TextFSM
必然抛出编码异常”的假设；确认的是静默重写输入，原假设未作为已发生缺陷保留。

| 变更 | 责任与契约 |
| --- | --- |
| `SavedConfig::LegacyIndex`、`Fleet#backup_all/#backup_one` | 每次批次创建独立共享索引，互斥构建并冻结元数据表；规范路径优先，唯一旧文件才迁移；无配置正文或全局缓存 |
| `SavedConfig(indexed: true)` | IPv4/IPv6 身份统一；zone 下划线不当作冒号。默认独立 SavedConfig 仍逐次实时查找 |
| `LegacyIndex#open`、`SavedConfigChanged` | 保留 NOFOLLOW/NONBLOCK/fstat；读取前后及目录项核对 dev/ino/mode/size/mtime/ctime，失效基线在凭据/连接器调用前失败，无原始 cause/正文 |
| `SavedConfig#parse`、模块加载测试 | 实际解析才 require ParseOutput；Netdisco 和 CLI 本地导出不加载 TextFSM，旧入口双顺序仍通过 |
| `ParseOutput#utf8/#call`、`TerminalRenderer` | 解析原字节副本严格 UTF-8 校验，复用严格终端渲染；无静默 scrub 或自动转码。原始配置、备份、导出和日志显示契约保持 |
| `Topology#neighbors`、v2 Diagnostic | 厂商模板选择/计数前验证原文；稳定 `invalid_output_encoding` 和 `saved_config_changed` 进入固定诊断词表 |

### 本地验收

命令、日志、依赖来源、源码和归档摘要见
[NC-09-10-verification.json](NC-09-10-verification.json)。
定向回归覆盖 legacy index、编码、模块加载、旧文件身份、路径锁、持久化、TextFSM、
拓扑及报告：**111 runs / 1426 assertions，0 failures/errors/skips**。
最终 `bundle exec rake ci` 退出 0：**421 runs / 4567 assertions，0 failures/errors/skips**；
154 个 Ruby 文件 lint、workflow lint、源码/历史/包扫描、120 文件构建及普通/最小
Bundler 隔离安装均通过。覆盖率 86/99 个文件、3754/3889 行、1237/1480 分支；
13 个未加载文件仍单列。安装烟测检查惰性加载、索引及快照失效、严格编码。

元数据快照不是文件系统事务，不能取代对目录、祖先和旧文件的保护；非合作写入者
和文件系统时间戳精度仍是边界。批内新出现的旧名称文件下一批才可见；规范文件
每次优先检查。没有真实其他编码设备样本，不增加 `source_encoding` 配置，后续
如有需求再用实际样本定义严格转码，当前默认仅接受有效 UTF-8 字节。
本机 macOS / Ruby 4.0.6 之外的远端矩阵、真实设备/固件和故障存储未验证。
NC-07C、NC-11 至 NC-15 的剩余内容继续按原计划推进，没有修改 VERSION、提交、推送或发布。

## 批次 H：NC-11 内存基线与累计输出预算

先在无累计预算的源码上运行 23 个独立样本，再实现预算。机器为 macOS arm64、
Apple M5（10 逻辑核、16 GiB）、Ruby 4.0.6、Bundler 4.0.20；依赖为正式
expect-pty 0.5.0 / textfsm 0.2.0。原始 JSON、外部 time 输出、基线运行脚本及
源码摘要保存在 [benchmarks/NC-11](benchmarks/NC-11/)。结果中的 time_log 保留
原运行路径，同名原始文件已一并归档。计时和测量数值原样保留；归档仅将源码摘要改为显式的
path/sha256 对象，避免 authentication 文件名加摘要被扫描器误识别为凭据，未扩大
扫描白名单。未归档格式的原始报告仍在忽略的 tmp 目录，其摘要也记入验收 JSON。

基准覆盖假传输及真实本地 PTY，分开测量 response、render、clean、parse、collect
和 retain，并记录 Result.output 首次及重复调用成本。最大计划正文为 128 MiB，
逐个样本运行；不生成最大组合的笛卡尔积。另有 debug 日志样本，正常执行输出校验、
关闭和 PTY waitpid 回收。默认日志等级没有为测试而改变；计数 logger 不留存正文。

| 样本 | 已发送命令 / 完整保留步骤 | 峰值 RSS |
| --- | --- | --- |
| 假传输，1 MiB × 100，默认无累计预算 | 100 / 100 | 508182528 B（484.64 MiB） |
| 假传输，同计划，8 MiB 累计预算 | 8 / 8 | 104857600 B（100 MiB） |
| 本地 PTY，1 MiB × 10，默认无累计预算 | 10 / 10 | 218152960 B（208.05 MiB） |
| 本地 PTY，同计划，2 MiB 累计预算 | 2 / 2 | 139870208 B（133.39 MiB） |

预算样本执行的工作量不同，不能作为同工作量的内存下降百分比。RSS 为外部 time
报告的工作进程峰值，不是整个主机或所有子进程之和；分配对象数不是分配字节数。
100 条基线的 Result.output 一次约 0.0098 秒，重复五次约 0.0543 秒；只是一台机器
上的观测，没有因此改变 Result 缓存或默认完整输出契约。

`max_script_output_bytes` 默认 nil，保持兼容；可通过 Configuration、YAML、ENV
及 CLI 显式启用。每个 Execution 累计主命令及钩子查询的原始响应字节（包含提示、
分页和不捕获的输出），登录/特权认证仍受原单响应限制。发送前、完整响应记录后及
钩子结束时检查；触发后保留已完成步骤、失败位置和已确认 TFTP 回执，不自动重试。
它阻止继续发送，不是 RSS 或读取中硬上限；最后一个有界响应可令累计值超过预算。

新增回归先确认缺失接口；另有提示符回调耗尽预算仍发送主命令的失败探针，修复后
在真正发送前再次检查。定向回归 **117 runs / 1667 assertions** 全绿。
`bundle exec rake ci` 通过：**437 runs / 4731 assertions，0 failures/errors/skips**，
159 个 Ruby 文件 lint、workflow lint、源码/历史/包扫描、9 个基准烟测、120 文件
构建和普通/最小 Bundler 隔离安装均通过。文档标题修正后单独重跑打包及安装验证。
详细命令、产物摘要和 WIP 核对见 [NC-11-verification.json](NC-11-verification.json)。

本机之外的矩阵、真实设备及实际大型配置分布未验证；没有性能 SLA、无界缓存、
共享有状态解析器、步骤丢弃或真实配置样本。NC-12 至 NC-15 及可选 NC-07C 的
实施/适用性审计继续按任务书收口；没有修改 VERSION、提交、推送或发布。

## 批次 I：NC-13、NC-14 与 NC-15 收口

新增覆盖率机器报告，记录每个文件的行/分支计数、未命中位置、未加载文件，以及实际
Ruby/平台/依赖版本。NC-00 三个已有组和库总计形成同环境 ratchet；其他 Ruby 不直接
套用分母，保持原 80% 门槛并独立出报告。NC-00 没有逐文件数据，本轮未捏造该历史基线。
覆盖率判定不替代隐私、互斥、期限、部分成功、完成证据、持久性和退出码行为断言。

新覆盖率接口的定向测试先复现 3 个错误；首次接入 ratchet 后，442 条业务/工具测试
虽绿，整体仍正确失败：脱敏组 15/16 分支低于 NC-00 的 19/20。机器报告定位到
Redactor.remember 的 nil/空字符串分支，补上空值和重复登记过程中已有分片仍被保护的
断言后，达到 16/16；没有降低门槛或添加扫描豁免。

最低依赖 Gemfile 固定 expect-pty 0.5.0、textfsm 0.2.0，普通矩阵仍按允许范围解析。
CI 增加 Ubuntu / Ruby 3.2、4.0 的最低组合测试/安装通道，所有通道分别上传覆盖率及
依赖报告。本地两条链的关键依赖当前相同，这不是不同版本组合已完成的声明。

NC-14 审计复用原有 ConnectorFake、PTY 和各厂商正负/部分输出测试，新增明确的
完整/截断 PAN-OS 单行引号对照；[夹具索引](../../test/fixtures/README.md) 记录来源、
预期语义及 unknown 固件范围。没有新增厂商功能或未经现场证实的命令。
NC-15 补齐公开业务方法的返回/抛错表、三层确认、迁移影响及尚未启用能力；stale_plan
仍在写入前直接抛出 DeviceError。README 保持关键用法，详细契约放在运行用户文档。

本机 `bundle exec rake ci` 通过：**442 runs / 4758 assertions，0 failures/errors/skips**；
160 个文件 lint、workflow lint、源码/历史/包扫描、9 个基准 smoke、120 文件构建与
普通/最小 Bundler 隔离安装通过。最低依赖组合的 `rake test package:verify` 同样为
**442 / 4758**，两次构建 gem 字节相同。覆盖率为 86/99 个文件、3788/3916 行、
1260/1498 分支；NC-00 比较通过，13 个未加载文件单列。

报告保存在 [coverage/NC-13-normal.json](coverage/NC-13-normal.json) 和
[coverage/NC-13-minimum.json](coverage/NC-13-minimum.json)；命令、日志、源码及
归档摘要见 [NC-13-15-verification.json](NC-13-15-verification.json)。其余说明及
最终工作包状态以 [FINAL-AUDIT.md](FINAL-AUDIT.md) 为准。
