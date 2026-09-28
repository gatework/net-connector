# 验证、依赖与敏感数据

在项目根目录执行：

```sh
bundle install
script/ci
```

`bundle exec rake ci` 和 `bundle exec rake release:check` 使用同一套检查。
`release:check` 可以在仍有 `Unreleased` 变更时运行，不执行发布。

## 检查范围

| 步骤 | 内容 |
| --- | --- |
| `security:check` | 扫描待提交源码和可用的完整 Git 历史；拒绝混入源码的本地凭据、配置和产物 |
| `lint` | 对库、脚本、示例、测试、Gemfile、gemspec 和 Rakefile 执行 RuboCop；引擎及 Netdisco 方法上限为 40 行、ABC 60 |
| `lint:workflows` | 用 actionlint 校验 GitHub Actions 工作流 |
| `test` | 执行全部 Minitest，列出未加载文件，并执行关键模块的行与分支覆盖率门槛；敏感信息和发布测试使用临时文件、临时仓库与模拟远端响应 |
| `benchmark:smoke` | 每项 16 KiB 的合成工作负载，验证假传输、本地 PTY、配置清理、解析、结果保留与日志；只检查正确性，不按机器速度设门槛 |
| `package:verify` | 构建 gem，检查元数据、文件白名单、源文件字节和执行位，扫描解包内容及元数据，再进行隔离安装 |

隔离安装清除当前 Bundler 和 Ruby 注入变量，分别验证普通 `gem install`
和只有 `net-connector` 依赖的最小 Bundler 应用。烟测加载全部厂商，使用本地
PTY 子进程采集配置，读取包内 TextFSM 模板，并检查 CLI。它不连接网络设备，
也不证明现场设备协议或真实发布服务已验收。

## 配置输出隐私回归

`test/output_sensitive_test.rb` 使用每次运行新生成、不同于登录凭据的假秘密，
覆盖 text/info、text/debug、raw 和外部 logger；检查成功采集、控制符分片、
超时、输出超限、设备错误、厂商追加查询、命令替换、结果选择、清理异常和
日志器故障。断言包含错误 message/output、底层 message/backtrace、
`exception.full_message` 及 cause，同时核对完整结果、备份字节与 SHA-256。
还验证普通命令诊断恢复、失败重连、非局部退出及元数据复制。

`test/transport_test.rb` 另用本地 Ruby PTY 验证配置日志隔离、控制字符、
真实读取超时和子进程回收。厂商覆盖来自合成输出，固件范围为 unknown；
这些结果不构成真实设备、真实凭据或生产 TFTP 服务验收。

```sh
bundle exec ruby -Ilib:test test/output_sensitive_test.rb
bundle exec ruby -Ilib:test test/redaction_contract_test.rb
bundle exec ruby -Ilib:test test/transport_test.rb
bundle exec ruby -Ilib:test test/collection_contract_test.rb
bundle exec ruby -Ilib:test test/running_config_strategy_test.rb
bundle exec ruby -Ilib:test test/module_loading_test.rb
```

实施记录保存在源码树的 `docs/optimization/`，不进入 gem 发布白名单。
每个工作包的初始状态、已运行命令与未验证边界均以该记录中的日期和环境为限。

`test/module_loading_test.rb` 在独立进程中分别检查设备入口与厂商策略先加载、
公共 API 先加载两种顺序，确认业务流程可用、公共层无厂商别名、没有额外厂商
或 TextFSM 被提前加载。`test/running_config_strategy_test.rb` 检查同次采集的策略
状态贯穿响应校验、步骤选择和清理，覆盖子类 `super`、其他 Fiber 的离线清理、
嵌套采集拒绝及失败重连。两者共同约束模块边界和执行行为。

## 日志与命名边界

`test/logging_test.rb` 检查安全事件对象、文本与 JSON formatter、会话/命令关联、脚本来源、响应字节和耗时；覆盖 logger 级别在运行中变化、重连分配新标识、回调失败、逐行输出的命令归属，以及调用方 logger 的资源所有权。自定义字段不能覆盖上下文，复杂对象和非有限浮点数不会进入 JSON，敏感范围内的任意事件名称和载荷整体隐藏。

库、示例、测试和隔离安装烟测统一使用 `log_event`、`execute_command` / `execute_script`、`running_config`、单一 `tftp_backup` 回执和 Report。策略接口在 Profile 构造时校验，不通过旧方法名或可选旧钩子回退。历史版本说明和 `docs/optimization/` 的原始记录保留当时名称，不是当前可调用接口。

## 离线内存基准与累计预算

`bundle exec ruby script/benchmark_memory.rb --suite baseline --directory tmp/benchmarks/my-run`
逐个启动独立 Ruby 进程，报告 1/8/32 MiB 响应、1/10/100 命令、1/4/16 并发的
选定组合，不运行最大值的笛卡尔积。单个样本计划响应正文不得超过 128 MiB，
已有输出目录拒绝覆盖。较小的 `--suite smoke` 纳入 `rake ci`。

每个样本保留机器信息、实际依赖版本、源码摘要、外部 `/usr/bin/time` 原始统计，
以及各阶段的分配对象数、单调耗时、`ps` 测得的 RSS 端点。峰值是 time 的进程
高水位，不是 worker/PTY 子进程 RSS 总和；构造夹具和连接在阶段计时前完成，
仍计入进程峰值。GC 正常启用。默认日志采用 Configuration 默认值，另有显式
debug Logger 计数目标样本；不关闭协议检查、丢弃步骤或共享有状态 Parser。

响应构造、终端渲染、配置清理、解析、完整采集与步骤保留分别计量。
`Result#output` 单次与重复调用单列，不把对象分配数误当字节数，也不据一次采样
承诺内存降低比例。带 `--script-budget-bytes N` 的 retain 样本同时验证预算失败
及保留输出；它执行的命令较少，不能与完整脚本称为相同工作量的性能提升。
基准脚本和原始实施记录不进入运行 gem。

`test/script_output_budget_test.rb` 覆盖默认关闭、精确边界、多字节、分页的原始字节、
各类钩子追加查询、提示符回调、异常被吞掉后仍失败、故障位置、完整步骤、新脚本
重置、原单响应限制及 TFTP 回执。输出隐私矩阵保留日志和原始结果双向断言，
真实 PTY 测试核对关闭和 waitpid 回收；设置测试验证优先级、批内不变及离线导出。

## 覆盖率与复杂度门槛

`script/coverage.rb` 在测试加载源码前启动 Ruby `Coverage`，由
`script/coverage_report.rb` 检查以下三个组。各组分别按实际可执行行、分支
累计命中比例，不取文件百分比的平均值，不先四舍五入再判断。

| 组 | 文件范围 | 行 / 分支最低覆盖率 |
| --- | --- | --- |
| 核心引擎 | `lib/net/connector/engine/**/*.rb` | 80% / 80% |
| 脱敏与错误处理 | `lib/net/connector/engine/errors.rb`，包含 `Redactor` | 80% / 80% |
| 批量并发 | `lib/net/connector/netdisco/worker.rb` | 80% / 80% |

关键组为空、任一关键文件未测量或组内没有可执行行时均失败。没有分支的组
不需要分支命中，但仍须通过行覆盖率及文件加载检查。
全库输出中的“未加载文件”表示当前测试进程没有采集到数据：可能只在隔离
子进程中加载，也可能在覆盖率启动前被 Bundler 加载，不等同于从未测试。
报告会逐项列出路径，不自动预加载源码，也不把子进程覆盖率并入主进程。

每次完整测试同时写入 `tmp/coverage/summary.json`：Ruby 描述和平台、实际依赖版本、
库文件总数/已加载数、逐文件及上述三个组的行/分支计数、未命中位置和未加载文件。
`NC_COVERAGE_OUTPUT` 只改变输出位置，不改变门槛。报告不保存配置正文、
环境变量值或源码片段。CI 每个 Ruby/平台和最低依赖任务分别上传报告。

`script/coverage-baseline.json` 来自 NC-00 实测的初始 dirty 工作树，保存三个组及
已加载库总计的原始分数。Ruby 描述（含平台）相同时按整数交叉相乘比较，任一
行/分支比例下降均失败；不会自动更新基线。其他运行时标为 `not_comparable`，
继续执行原有 80% 门槛与全部行为测试，不能把跨 Ruby 插桩差异当业务回归。
NC-00 未保存逐文件数据，因此本轮不伪造逐文件历史下限；现在的逐文件报告供后续
同环境审阅建立更细基线。基线更新必须审阅，不能用新的低值覆盖旧值来消除失败。

门槛失败由 `Minitest.after_run` 返回非零退出码，`rake test`、`ci`、
`release:check` 都会失败；测试本身的失败也不会被达标的覆盖率覆盖。
单文件开发检查请用 `bundle exec ruby -Ilib -Itest test/<名称>_test.rb`，
完整预检仍须运行全部测试，不提供环境变量来降低发布门槛。

`.rubocop.yml` 对 `engine/` 和 `netdisco/` 启用 `Metrics/MethodLength`
（40）及 `Metrics/AbcSize`（60）。这是初始上限；按职责拆分超限方法，
不通过自动生成文件豁免维持基线。方法行数按 RuboCop 口径计算。

## 平台与工具

CI 矩阵为 Ubuntu 24.04 / macOS 15 × Ruby 3.2、3.3、3.4、4.0。
GitHub Actions 固定提交 SHA；Gitleaks 与 actionlint 固定版本和各平台归档
SHA-256，首次使用时从官方 GitHub Release 下载，缓存到 `tmp/tools/`。
已有工具归档和可执行文件也会再次校验。初次安装依赖和下载工具需要联网；
隔离安装复用本次 Bundler 安装所得的 gem 缓存。Bundler 自身优先使用缓存
安装；若它是 Ruby 随附且没有缓存的默认 gem，则直接加载该精确版本。

## 依赖与打包

`test/topology_stages_test.rb` 使用 `test/support/topology_fixture.rb` 的四类合成对话，验证视图转换、先读回后保存、各阶段超时、读回不匹配/不完整、审批与实际查询一致、旧计划拒绝、保存完成证据和重连不重放。Queue 固定读回完成至保存之前的竞争窗口，检查线程和 Fiber 所有权。PAN-OS 无候选隔离证据时在 I/O 前拒绝自动改写，保留只读解析。夹具的官方来源、推断和 unknown 固件范围见 `test/fixtures/topology/README.md`；测试不等于现场设备认证。普通及最小 Bundler 隔离安装另用本地 PTY 验证分阶段拓扑流程及读回输出敏感标记。

`test/tftp_boundary_test.rb` 验证内置策略在首次 I/O 前拒绝不支持的参数组合，使用 Queue 固定 H3C 源探测后的竞争窗口，检查线程/Fiber 拒绝。上传确认后的日志、命令清理、租约清理、路径和元数据钩子失败保留回执且不重传；随机假秘密不进入新错误正文。统一回执测试核对配置来源、实际路径、设备报告等级和冻结字段；Fleet 拒绝第三方和子类提供的完成事实。既有成功/失败/echo/控制符证据用同一套合成夹具继续测试，来源和 unknown 固件范围见 `test/fixtures/tftp/README.md`。普通及最小 Bundler 安装通过本地 PTY 验证唯一的 TFTP 回执入口，没有连接真实 TFTP 服务器或上传配置。

`test/netdisco_reporting_test.rb` 覆盖 strict/selected 的状态决策矩阵、显式 CLI 退出码、统一 schema 2、Outcome 的耗时与诊断成员、Fleet/ResultStore 的 Report 契约，以及部分成功/回调/报告错误阻止 selected 成功。动态假秘密放入异常消息、输出、命令、source、line、phase、code 和自定义类型名，报告与私有 JSON 不得含它。受控文件/TFTP 回执阶段跨 Worker 复制仍保留，普通文件异常不能冒充设备产物。可控时钟让 UTC 倒退而单调时间前进，断言设备及批次耗时准确且无负值；没有用固定睡眠推断时间行为。

`test/backup_lock_test.rb` 通过 Queue、独立 Ruby 进程及可控单调时钟检查采集前互斥、有限等待、锁释放、线程/Fiber/回调递归、路径别名、私有权限、硬链接/FIFO 拒绝和符号链接替换。`test/backup_identity_test.rb` 验证规范地址命名、改名后的稳定身份、mtime、非普通文件拒绝和非规范文件不参与比较；稳定锁文件不作为多余备份计数。

`test/module_loading_test.rb` 在独立 Ruby 进程核验 Netdisco 加载、CLI 离线导出和实际解析的 `$LOADED_FEATURES`；当前设备与厂商入口的双加载顺序分别检查，确认公共层无厂商别名，Storage 不加载设备。`test/parsing_encoding_test.rb` 覆盖 UTF-8/二进制标签、非法 UTF-8、Latin-1 字节、回车/退格/ANSI、被控制符隐藏的非法输入、分裂多字节字符、原备份不变及拓扑不能把异常输出当作空表。原有 PAN-OS 引号多行拒绝及多线程独立解析测试保留。没有真实其他编码设备样本，本次不增加自动或显式设备编码配置；严格转码能力留待实际设备需求验证。

`test/file_persistence_test.rb` 对临时文件创建、写入、flush/fsync、rename、父目录打开/同步及收尾注入故障，检查磁盘内容、阶段回执、无正文诊断、Fleet 部分成功及报告/导出行为。同步不支持与 EIO 分开，第三方回执子类不能供应完成事实。隔离安装烟测还通过真实本地 PTY 采集写入，验证私有锁、目录同步及安全读取。本地 macOS 测试证明协议与故障分支；Linux、网络文件系统、真实断电恢复需单独验证。

`test/netdisco_budget_test.rb` 用合成响应、可控单调时钟及本地 TCP HTTP 端点验证单页/累计字节、记录数、分页、认证和兼容查询的共用期限。流式上限覆盖 chunked、无长度和虚报长度；超限时设备工厂与凭据解析器均未调用。阻塞读取场景断言关闭自有传输并回收观察线程，不靠固定 sleep 判断竞态。注入 requester 只验证返回后的预算，不声称能强制中止任意回调。

`test/netdisco_settings_test.rb` 验证批内 ENV 策略变化被隔离、逐设备凭据轮换、后续批次刷新、批准计划不重抓清单、CLI/ENV/YAML 优先级及离线导出。策略快照的序列化和 inspect 不含秘密；非法枚举、采样范围及预算在创建 Fleet 或设备前拒绝。默认预算没有经过生产容量压测，真实 Netdisco 及多平台远端矩阵仍需单独验收。

运行依赖写在 `net-connector.gemspec`，包括直接使用的、可能从 Ruby 默认
安装中拆出的标准库 gem。开发工具只写在 Gemfile，不进入运行依赖。
共享脱敏要求 `expect-pty ~> 0.5.0`，使用已发布的公共 `Expect::Redactor`。
开发及隔离安装检查使用正式依赖包，不再需要本地 expect 补丁或联调环境包装脚本。
开发用 `parallel` 保持 1.x，以支持 Ruby 3.2。

本项目是库，`Gemfile.lock` 仅作本地开发记录并被忽略；各 Ruby 版本的 CI
分别解析兼容依赖。应用使用者应在自己的应用中提交 lockfile。测试和打包
脚本通过隔离安装检查运行依赖，避免依赖开发环境里偶然存在的 gem。

`gemfiles/minimum.gemfile` 固定关键业务依赖下限 expect-pty 0.5.0、textfsm 0.2.0；
标准库和开发工具仍按主 Gemfile 的兼容范围解析。普通矩阵检查允许版本的正常解析，
另在 Ubuntu / Ruby 3.2、4.0 检查下限组合的全量测试与隔离安装。本地复现：

```sh
BUNDLE_GEMFILE=gemfiles/minimum.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/minimum.gemfile bundle exec rake test package:verify
```

这不是所有传递依赖最旧版本的笛卡尔积，也不声称本地 macOS 运行证明远端矩阵通过。
当前这两个关键依赖的正常解析与下限恰好相同，报告仍记录实际版本，供以后比较。
开发锁文件均忽略；gemspec 保持兼容范围，基准、夹具、兼容 Gemfile 和审阅报告均不进 gem。

gem 只收录库代码、TextFSM 模板、CLI、架构/验证/发布文档、README、LICENSE、
CHANGELOG、SECURITY 和 CONTRIBUTING。测试、示例、发布工具、工作流、本地评审快照、配置和备份不进入包。
更改 gemspec 后，实际归档仍须通过独立的文件白名单检查。

## 敏感数据

Gitleaks 默认规则之外，还检查网络设备密码/SNMP community 配置、环境变量
中的字面量凭据和私有 IPv4 地址。公开示例使用 `replace-me`、环境变量引用和
文档地址（例如 `192.0.2.1`）。代码和测试不享受目录级豁免；内联
`gitleaks:allow` 或 `.gitleaksignore` 也不能绕过这里的扫描。

有 Git 仓库时，源码检查覆盖已跟踪文件和未忽略的新文件，并以 `--all`
检查本地可用引用的历史。CI 使用 `fetch-depth: 0`，浅克隆会被拒绝。
没有 Git 元数据或没有提交时，只执行源码检查并明确报告历史检查不可用；
临时测试仓库中已删除敏感数据的提交也必须能被历史扫描检出。

扫描失败会停止后续构建或发布。日志和 `tmp/security/*.json` 报告仅记录规则、
文件与行号，不记录匹配文本或秘密值；报告权限为 `0600`。最终 gem 和
`--artifact` 重试同样接受检查。扫描器异常、缺失报告也按失败处理。

`.gitignore` 排除本地环境文件、配置、凭据、SSH 密钥、设备备份、日志、报告、
构建包、依赖缓存与编辑器文件；保留 `.env.example`、厂商代码与工作流。
忽略规则不会移除已经跟踪的文件，源码检查会拒绝已跟踪的禁入路径。
已有 Git 暂存区仍需包含最终脱敏后的修改，避免提交旧的暂存内容。

发现真实敏感数据时，在源码或示例中替换为占位值，并检查历史及已分发的包。
若凭据已经泄露，需在对应系统撤销或轮换；仅修改示例不能使旧凭据失效。
扫描工具不会自动改写 Git 历史或真实设备备份。规则用于拦截常见泄露，
发布前仍需人工确认设备名称、拓扑和业务配置等上下文信息是否适合公开。

## JSON 2 发布依赖与 JSON 3 源码兼容分开验证

默认及最低依赖任务验证实际发布依赖。TextFSM 0.2.0 的公开声明仍为 `json ~> 2.0`；
本地同版本 gem 的修订不能证明普通消费者能安装 JSON 3。

CI 的 `json3-source-compatibility` 在 Ruby 3.2 / 4.0 检出固定 TextFSM commit
`733340de378f2d7fbe530b48f2cf1dd6c30c69b0`，应用仓库内
`script/compatibility/textfsm-json3.patch`，只放宽依赖声明，再执行完整测试和真实打包隔离安装。
该任务明确代表尚未发布依赖声明下的源码兼容性；不自动发布、替换正式依赖或修改用户的全局 gem。

复现时，在 `tmp/json3/textfsm` 准备该源码并应用补丁，然后运行：

```sh
BUNDLE_GEMFILE=gemfiles/json3.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/json3.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/json3.gemfile bundle exec ruby script/verify_json3.rb
```

## 批次入口与密钥并发回归

`test/known_hosts_test.rb` 使用临时密钥文件、多进程同步屏障和本地 PTY，
验证并发替换/首次登记、不相关主机保留、登录失败不提交、非标准端口以及并发密钥冲突。
这些测试不连接真实 SSH 服务器。

`test/examples_test.rb` 验证示例进程退出码与报告策略一致、报告写入错误、统一 devices 结构、
TFTP 远端未核验回执以及自定义日志目录；离线复核同时支持历史 outcomes 和新 devices 报告。
`test/tftp_verification_test.rb` 验证空文件、旧文件、符号链接、目录逃逸和 verified 策略。

## Ruby 惯用法重构回归

`test/profile_contract_test.rb` 验证 protected 交互钩子覆盖并调用 `super` 后，登录与命令确认仍采用扩展规则。
`test/engine_boundary_test.rb` 覆盖 finalize 的 nil/false 返回、回调重入、throw 与 open 块的 break、
登录钩子异常/中断清理及后续重新连接；原有恢复测试继续限制最多一次连接恢复。
`test/netdisco_settings_test.rb` 验证显式 nil/false 优先于默认值，以及预算校验先于来源查询校验。
输出敏感性、线程/Fiber 所有权、完成步骤保留由原有输出、拓扑和批次回归共同验证。

实施记录使用当前工作区文件和方法可见性快照，区别已有改动与本轮增量，不以 Git HEAD 冒充修改前基线。
源码根目录 `RENAMES.md` 记录批准的改名与兼容边界。完整验收仍运行 `bundle exec rake ci`；
临时 PostgreSQL 使用 `bundle exec rake test:postgres`，可通过 `NC_TEST_PG_BINDIR` 指定服务端工具目录。
最低 Ruby 3.2 必须在对应解释器中运行 lint/test；RuboCop 的 TargetRubyVersion 和 Ruby 4.0 测试不能替代此项。
