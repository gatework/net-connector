# Ruby 惯用法重构：命名与兼容边界

本次以 2026-09-28 开始实施时的工作区为基线，包含已有未提交改动。
以下五项改名已获批准；不保留旧名别名。引用数统计原 `lib/` 中的调用，不含定义；
新测试及历史归档不计入。归档中的历史名称继续保留。

| 原名称 | 当前名称 | 可见性 | 原调用数 | 风险及迁移 |
| --- | --- | --- | ---: | --- |
| `Base#login_dialogues` | `login_interactions` | protected | 1 | 子类覆盖须改名；继续支持 `super`，返回 Interaction 数组 |
| `Base#confirmation_dialogues` | `confirmation_interactions` | protected | 1 | 子类覆盖须改名；继续支持 `super`，返回 Interaction 数组 |
| `Fleet#backup_one` | `backup_device` | private | 1 | 内部调用同步调整；路径锁及备份回执不变 |
| `Fleet#tftp_backup_one` | `tftp_backup_device` | private | 2 | 内部调用同步调整；上传、核验及归档流程不变 |
| `Fleet#run_one` | `run_device` | private | 2 | 内部调用同步调整；动态凭据、连接关闭与部分成功语义不变 |

## 对象协作

`Settings#raw`、`Settings#config_hash` 从 private 改为 protected，供同类对象通过显式
接收者调用，替代两处 `send`。它们不是应用层公开接口；策略快照仍只包含非敏感设置。

Session 的公开方法保持原可见性，私有实现集中放在 private 段。新增的 `login_once`、
Base 执行器构造与结果收尾、Settings 来源参数解析助手均为 private。

## 保留项

- `perform_one` 负责设备操作及关闭收尾，职责与 `run_device` 不同，保留原名。
- 保留 `SavedConfig`、配置采集钩子、公开方法参数、Result/Data 成员、日志和报告字段。
- 保留 RunningConfig 对私有策略作用域和 protected 结果选择钩子的两处受控 `send`；
  不为消除反射而公开策略绑定或破坏继承链。
- 保留 Fleet/Settings 的哨兵，避免将显式 nil/false 与省略混同。
- 校验规则的异常、允许值及复制语义不同，本轮不提取通用 Validation 模块、配置 DSL 或参数对象。

## 实施与验证顺序

1. 保存文件及方法可见性基线；补充钩子、finalize 和 Settings 行为测试并在修改前运行。
2. 单独搬移 Session 私有方法并核对可见性；随后提取登录、脚本收尾和设置解析职责。
3. 应用上述改名，启用 Naming 与八项 Style 规则，逐项核对块、返回值及异常边界。
4. 同步开发约定、架构和迁移说明；运行完整 CI、可用的最低版本和临时数据库验证。

验收以行为测试、覆盖率、打包安装和本轮增量为依据；本地模拟与 PTY 不代表真实设备验证。

## 本次验收记录（2026-09-28）

| 环境 / 命令 | 结果 |
| --- | --- |
| macOS Ruby 4.0.7：`bundle exec rake ci` | 171 文件 lint、源码/历史扫描、工作流检查、531 测试 / 6374 断言、覆盖率门槛、基准烟测、121 文件 gem 检查及普通 Ruby/Bundler 隔离安装通过 |
| Docker Ruby 3.2.11 aarch64-linux：`bundle exec rake lint test` | 当前源码隔离副本，171 文件 lint、531 测试 / 6374 断言及覆盖率门槛通过 |
| macOS PostgreSQL 18：`NC_TEST_PG_BINDIR=/opt/homebrew/opt/postgresql@18/bin bundle exec rake test:postgres` | 临时数据库，11 测试 / 148 断言通过 |
| 方法可见性与增量核对 | 四个类仅存在批准的调整；活跃源码无旧名；生产代码净减少 10 行，归档基线未改 |

新增 7 个行为测试，未放宽现有断言。Ruby 3.2 的依赖安装和锁文件解析仅发生在隔离副本，
未修改工作区依赖声明或锁文件。完整执行日志保存在本地忽略目录 `tmp/ruby-refactor-*.log`。
远端 CI、Ruby 3.3/3.4、真实 SSH/Telnet 设备与真实 TFTP 服务端本次未运行。

## 主任务书增量重构（2026-09-28）

本轮以以上改动完成后的工作区为基线；原有未提交修改保留。修改前保存了 258 个
工作区文件的内容和 SHA-256，以及主要类的方法可见性，位于本地忽略目录
`tmp/ruby-incremental-baseline/`。仅审阅相对此快照的增量，不以 HEAD 代替工作区基线。

| 原名称 | 本轮名称 | 边界与理由 |
| --- | --- | --- |
| Execution `@prompt` | `@prompt_resolver` | 内部保存回调；公开 `prompt:` 与 Session 提示符字段保持 |
| Base `private_result` | `sensitive_result` | 局部变量表达结果敏感上下文 |
| RunningConfig `content?` | `config_body?` | 私有方法判断配置正文 |
| Script.parse `number` | `line_number` | 局部变量表达一基来源行号 |
| Fleet `close_error_status:` | `partial_status:` | 私有调用链覆盖关闭失败及已产生回执的操作失败 |
| Execution `check_output_budget!` | `validate_send_budget!` / `validate_response_budget!` | 私有入口区分发送前 >= 与响应后 >；共享原错误构造 |
| Profile::Builder `check_block!` | `validate_block!` | 私有抛错校验统一命名 |
| InventoryBudget `check_limit!` | `validate_limit!` | 私有抛错校验统一命名 |

按本轮用户要求，抛错校验统一使用 `validate_*!`，库代码不再混用 `check_*`。
历史迁移表中的旧名称保留。现有 `@last_executed_command`、`report`、
`settings_snapshot` 和 `success_policy` 已准确，未再次改名。

Worker 新增内部协作方法 `.validate_concurrency!`，由构造器和 Fleet 原预检位置
共同调用；不再为预检丢弃临时 Worker。类型、范围、错误文案和拒绝顺序保持。
`Batch#counts` 使用 `map(&:status).tally`，保持插入顺序及缺失键 nil。

Configuration/Profile 继续保留各自校验：字符串、可选值和错误上下文不相同；
有限时间转换已共用 `Expect.duration`，不为两段短包装新增模块。
值对象的嵌套复制/冻结差异不在本轮修改，不新增输入限制、依赖或公开接口迁移。
受保护钩子、动态凭据、完成证据、锁与敏感输出边界保持。

新增三项行为测试，在生产代码重构前通过：状态计数的空集合、未知/重复状态、
键顺序和缺失键；两个批次入口的非法并发输入在清单、目录、凭据和连接器之前拒绝；
Worker 接受并发范围两个端点。预算和钩子复用既有行为测试。
新增两项 Layout 规则，只修复四处方法间空行，保留复杂度阈值与角色化异常变量名。

### 本轮验收结果

| 环境 / 命令 | 结果 |
| --- | --- |
| 修改前定向测试：两个 Netdisco 测试文件 | 52 测试 / 475 断言通过，包含本轮新增三项契约测试 |
| macOS Ruby 4.0.7：`bundle exec rake ci` | 171 文件 lint、534 测试 / 6467 断言、覆盖率门槛、源码/历史扫描、工作流校验、基准烟测及 121 文件 gem 隔离安装通过 |
| Docker Ruby 3.2.11 aarch64-linux：`bundle exec rake lint test` | 隔离源码副本，171 文件 lint、534 测试 / 6467 断言及覆盖率门槛通过 |
| 同一 Ruby 3.2：`BUNDLE_GEMFILE=gemfiles/minimum.gemfile bundle exec rake test package:verify` | expect-pty 0.5.0 / textfsm 0.2.0 / JSON 2，534 测试 / 6467 断言、打包扫描、普通 Ruby/Bundler 隔离安装及本地 PTY 通过 |
| PostgreSQL 18：`NC_TEST_PG_BINDIR=/opt/homebrew/opt/postgresql@18/bin bundle exec rake test:postgres` | 临时数据库 11 测试 / 148 断言通过 |
| 文档同步后的 `bundle exec rake package:verify`、`bundle exec rake security:check` | 最终发布文档随包校验、安装及源码/历史扫描通过 |
| 当前工作区增量与可见性核对 | 18 个文件；主要类原有 public/protected 实例方法可见性不变，库代码无 `check_*` 残留 |

命令退出状态均为 0。运行日志位于 `tmp/ruby-incremental-*.log`，本轮增量见
`tmp/ruby-incremental.diff`。Ruby 3.2 依赖安装与锁文件均留在隔离副本，未改主工作区依赖。
覆盖率历史比较因运行时描述不同显示 `not_comparable`；现有绝对门槛通过，未更新历史基线。
测试已有的方法重定义警告保留，没有通过禁用 warning 掩盖。
远端 CI、Ruby 3.3/3.4、真实 SSH/Telnet 设备及真实 TFTP 服务端未运行；未提交或发布。

## 完成度复核与补充（2026-09-28）

主任务书逐项复核后，补充两处 private 抛错校验的 bang 后缀：
`Profile#validate_terminal_size!`、`DatabaseClient#validate_connection_options!`。
原参数、返回的冻结副本、异常和调用位置保持，不新增别名。
`verify_descriptions!` 执行实际配置读回，`verify_lock!` 核对文件系统身份，继续使用
表达证据复核的 verify；公开的 `Session#assert_path_lock_order!` 保持原兼容接口。
统一的是参数/预算/声明校验范式，不将所有会抛异常的操作机械改为 validate。

### 值对象复制边界

新增 `test/value_object_contract_test.rb`，并补充生成拓扑计划的冻结测试；这些断言在
新增命名调整之前通过。它们记录当前可观察语义，不鼓励调用方修改共享成员。

| 对象 / 入口 | 直接验证的现有行为 | 本轮决定 |
| --- | --- | --- |
| `Backup.new` | Data 外层冻结；传入路径、摘要、Time 仍共享，调用方修改可见 | 保留；复制/深冻结是独立语义变更 |
| `TftpReceipt.new` / `with` | 字符串和 Time 复制冻结，修改输入不影响回执；with 重新校验 | 保留自定义 with，最低 Ruby 实测 |
| `PrivateFile::Receipt.new` | 路径复制冻结，原字符串可独立修改 | 保留；原生 Data#with 的跨 Ruby 差异单独记录 |
| `Outcome.new` / `with` | 构造保留传入 Time/文本引用；替换时间清除旧耗时，替换错误清除旧诊断；显式新值优先 | 保留领域更新逻辑，不换通用复制助手 |
| `Batch.new` | 外层冻结；传入数组、回调 Hash/文本及 Time 仍共享 | 保留；Fleet/Worker 生产路径的冻结不等于构造器承诺深冻结 |
| `Topology::Plan.new` / 规划入口 | 直接构造保留传入成员；实际规划冻结 evidence、changes、commands 和描述 | 区分直接构造与工厂保证；保留 formatter 返回字符串被原地冻结的行为 |

### 主任务书逐项结论

| 要求 | 当前证据与处理 |
| --- | --- |
| 1–2 目标、基线、工作区 | main / a4ec7e05cb82d18f95519b064caa4f3f5140263f；当前版本 0.6.0；修改前快照与 lint/test 已留存。已有依赖通过 bundle check，无需在主工作区重新安装；依赖安装发生在隔离副本 |
| 3 分层和能力组合 | 相对快照无目录、常量、依赖或能力模块变更；加载测试覆盖按需厂商与离线入口 |
| 4 内部命名 | 上表与本轮改名表覆盖所有候选；已准确名称保持，公开关键字和字段未改 |
| 5 集合、预算、Ruby 表达 | tally 的顺序/缺失键测试；预算全部检查点保留并用明确 validate 入口表达；不批量改写控制流、转发和 bang 方法 |
| 6 去重和 DSL | Worker 复用纯预检；Configuration/Profile 因语义与上下文区别保持局部校验；Builder 有限入口及显式字段列表保留 |
| 7 锁、错误、敏感性、证据和批次 | 增量未修改资源/锁/回执/凭据规则；现有敏感输出、预算、策略钩子、TFTP、拓扑、文件与报告测试纳入完整测试 |
| 8 值对象 | 上述六类对象均有直接行为测试；不引入复制、深冻结或输入限制；跨版本差异单列 |
| 9 风格规则 | Naming 与现有 Style 保留，增量启用两项 Layout；保留异常角色命名，不提高复杂度阈值；只修四处空行 |
| 10 验证 | 全量 CI、Ruby 3.2 默认/最低依赖、PostgreSQL 与隔离安装记录见前后验收表；真实设备及未执行平台不冒充通过 |
| 11 交付 | 分阶段改动、命名表、未做项和验证记录保存在本文件；历史归档不改，不提交或发布 |

补充接口审查对基线和当前源码分别加载全部内置厂商与 Netdisco，比较 168 个具名
模块/类的 public/protected 方法签名及自定义构造器参数：原有接口完全一致，
仅新增 Worker 内部协作方法 `.validate_concurrency!`。审查脚本与快照位于
`tmp/ruby-api-audit.rb`、`tmp/ruby-api-before.json`、`tmp/ruby-api-after.json`。

复核实测发现 `PrivateFile::Receipt#with(path: mutable_string)` 的路径冻结取决于
运行时：Ruby 3.2.11 为 false，Ruby 4.0.7 为 true。该类未像 TftpReceipt 一样
覆盖 Data#with；本轮保持现状。若今后统一重新校验/冻结，需要独立语义变更及迁移说明，
不能把跨版本差异当作已经修复。此观察仅使用合成路径，没有写设备或真实备份。

### 完成度复核后的最终验收

- 修改前定向回归：37 测试 / 842 断言通过，包含八项新增值对象/拓扑冻结测试。
- macOS Ruby 4.0.7 完整 `bundle exec rake ci`：172 文件 lint、542 测试 / 6580 断言、覆盖率门槛、源码与历史扫描、工作流校验、基准烟测、121 文件 gem 校验和普通 Ruby/Bundler 隔离安装均通过。
- Docker Ruby 3.2.11 默认依赖 `bundle exec rake lint test`：172 文件 lint、542 测试 / 6580 断言及覆盖率门槛通过。
- Docker Ruby 3.2.11 最低依赖 `BUNDLE_GEMFILE=gemfiles/minimum.gemfile bundle exec rake test package:verify`：542 测试 / 6580 断言、覆盖率门槛及打包/隔离安装/PTY 全部通过。
- 临时 PostgreSQL 18 集成：11 测试 / 148 断言通过。
- 相对修改前工作区累计 22 个文件变化，含 11 项新增行为测试；历史优化记录及覆盖率基线保持。生产代码仅局部命名、预算入口拆分、状态计数与并发预检整理。

以上命令退出状态均为 0，最终日志为 `tmp/ruby-completion-{ci,ruby32,postgres}.log`。
完整接口比较快照与本轮增量仍保存在前述 tmp 路径；Ruby 3.3/3.4、远端 CI 和真实
设备/TFTP 服务端未验证。不因全量本地门禁通过而宣称全平台或真实设备验证完成。
