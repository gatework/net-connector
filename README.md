# net-connector

`net-connector` 通过 SSH 或 Telnet 操作网络设备的命令行。它可以采集运行配置、保存私有备份、执行命令脚本、回答设备提示、记录脱敏会话日志，并在失败时返回结构化错误和已完成的步骤。

代码按职责组织：`engine/` 管理会话、传输、脚本、结果和日志；`device/` 集中设备入口、档案、配置采集/保存、备份和拓扑能力；`vendor/<厂商>/` 保存厂商差异；`storage/` 负责私有文件、路径锁和离线配置；`textfsm.rb` 提供唯一的 TextFSM 适配入口；`netdisco/` 负责清单和批量编排。每项设备能力的公开方法与实现放在一起，由 `Base` 组合，设计说明见[架构文档](docs/architecture.md)。用 `require "net/connector"` 加载设备 API，用 `require "net/connector/netdisco"` 加载 Netdisco 集成；厂商规则和 TextFSM 依赖按需加载。

支持 Ruby 3.2 及以上版本和 POSIX 系统。SSH 调用本机 OpenSSH，Telnet 需要本机安装 `telnet` 并显式选择。主要依赖为 [`expect-pty`](https://rubygems.org/gems/expect-pty) 0.5.0 及以上和 [`textfsm`](https://rubygems.org/gems/textfsm) 0.2.0 及以上。

脱敏直接复用 expect-pty 从 0.5.0 起公开的 `Expect::Redactor` 接口；连接器只管理秘密作用域和配置输出的隐私策略。

## 安装

```sh
gem install net-connector
```

```ruby
require "net/connector"
```

运行时依赖只声明所需最低版本，不设置缺少兼容性依据的上限；宿主应用通过自己的 Gemfile/锁文件选择版本。正式发布依赖的安装验证使用 JSON 2。RubyGems 上 textfsm 0.2.0 仍约束 json ~> 2.0；JSON 3 使用固定 TextFSM 源码和显式依赖声明补丁单独验证，不代表公开依赖已经支持 JSON 3。开发工具及兼容测试矩阵的版本约束不影响 gem 使用者。

示例脚本通过开发依赖 `dotenv` 自动读取项目根目录 `.env`（先执行 `bundle install`），已有进程环境变量优先；库和 CLI 本身不会隐式读取 `.env`。

## 支持的设备

`device.supports?(:tftp_backup)` 等能力查询不会连接设备，只表示该连接器实现了对应操作，不代表设备权限或固件一定支持。完整能力矩阵和扩展示例见[厂商能力](docs/architecture.md#厂商能力)。

| 厂商标识 | 设备系列 | 运行配置命令 | 保存配置命令 |
| --- | --- | --- | --- |
| `:h3c` | H3C Comware | `dis cur` | `save force` |
| `:h3c_wireless` | H3C 无线控制器 | `dis cur` | `save force` |
| `:cisco_ios` | Cisco IOS / IOS XE | `show running-config` | `copy running-config startup-config` |
| `:cisco_nxos` | Cisco NX-OS | `show running-config` | `copy run start` |
| `:radware` | Radware Alteon | `/cfg/dump` | `/cfg/save` |
| `:palo_alto` | Palo Alto PAN-OS | 候选视图中的 set 格式导出 | 不支持 |
| `:huawei` | 华为 | `dis cur` | `save force` |
| `:hillstone` | 山石 StoneOS | `show configuration running` | `save all` |

厂商标识仅使用上表的规范名称。厂商连接器位于 `Net::Connector` 下，例如 `Net::Connector::H3cWireless::Connector`。

## 登录与本地备份

```ruby
Net::Connector.open(:cisco_ios,
  host: "192.0.2.10", username: "admin", password: ENV.fetch("DEVICE_PASSWORD"),
  known_hosts: "/etc/net-connector/known_hosts", host_key_policy: :strict,
  log_file: "/var/log/net-connector/router.log") do |device|
  backup = device.backup(path: "/var/backups/router-running.cfg")
  puts "#{backup.bytes} 字节，SHA-256 #{backup.sha256}"
end
```

`open` 会在代码块结束或出错时关闭会话。`backup` 在采集前取得目标路径锁，持有到比较、保存和生成原有 `Backup` 元数据对象完成；采集失败不会覆盖旧备份。同路径争用默认立即抛出 `BackupBusy`（`code: :backup_busy`），需要有限等待可传 `lock_timeout: 2`，单位为秒。直接调用 `backup`；不要在已有 `with_operation` 会话租约内调用，否则会因锁顺序返回 `SessionBusy`。

写入使用 `0600` 临时文件、文件同步、原子替换及父目录同步。替换后同步或收尾失败会抛出 `BackupPersistenceError`，`error.backup` 保留已写文件的元数据，`error.receipt` 区分 `:committed`（持久性未确认）和 `:durable`（同步已完成）。目录同步不受支持对应 `:backup_durability_unsupported`，不会静默报告持久化成功，也不会自动重做设备采集。

调用方应创建并保护备份目录，运行配置可能含有设备凭据。同目录下的 `.net-connector-<摘要>.lock` 是私有的长期锁文件，正常释放不删除它。所有写入者须使用本库的锁协议；`NOFOLLOW` 不保护被外部替换的祖先目录。锁名保守合并大小写及 Unicode 等价写法，实际备份文件名不变；在区分大小写的文件系统上，这些名称也会串行。

## 设备发起的 TFTP 备份

`tftp_backup` 让设备把原生配置直接上传到 TFTP 服务器，命令和提示交互由厂商策略提供。H3C 和华为从设备文件读取源配置，例如：

```ruby
Net::Connector.open(:huawei, host: "192.0.2.20", username: ENV.fetch("DEVICE_USERNAME"),
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  transfer = device.tftp_backup(host: "192.0.2.30", source_file: "flash:/startup.cfg")
  puts "已上传 #{transfer.path} 到 #{transfer.server}"
end
```

示例会下发 `tftp 192.0.2.30 put flash:/startup.cfg`；可传入 `path: "site/switch.cfg"` 指定目标文件名。H3C 默认通过 `display startup` 查找保存配置；华为因型号差异需要显式指定 `source_file:`。Cisco IOS 使用交互式 `copy running-config tftp:`；Nexus 9000 默认使用 `vrf management`，可用 `vrf:` 覆盖。山石导出已保存的启动配置，Radware Alteon 生成 `.tgz` 并处理私钥及 `mansync` 提示，PAN-OS 使用固定的 `running-config.xml` 文件名。其他厂商默认使用 `<管理地址>.cfg`。

只有设备回显确认传输完成，`tftp_backup` 才返回不可变的 `TftpReceipt`。回执直接包含 `server`、实际目标 `path`、`completed_at`、`configuration_kind`、`source_file`、`format`、`requested_path`、`verification` 和 `server_sha256`。明确失败对应 `:transfer_failed`，缺少成功证据对应 `:transfer_unconfirmed`。本方法不读取服务器上的文件。TFTP 不加密配置数据，应限制在合适的管理网络中使用。

回执的当前验证等级为 `:device_reported`，服务器摘要为 `nil`。H3C 自动探测结果标为 `:startup`；H3C/华为显式文件标为 `:saved_file`，格式为 `:unknown`，不凭扩展名推断内容。山石未指定文件名时 `requested_path` 为 `nil`，`path` 保留设备生成名称。

策略先校验参数组合，再在同一次会话租约中完成源探测、上传、证据检查和收尾。上传已确认但日志或清理失败时抛出 `TftpCompletionError`，通过 `error.receipt` 保留完成事实。显式请求与实际路径不同返回 `:transfer_path_mismatch`；实际路径无法安全确认返回 `:transfer_path_unconfirmed`，此时回执的 `path` 为 `nil`。这些错误不会自动重传；Fleet 保留上传事实并标为 `reported_with_error`。

可运行[单设备示例](examples/device_tftp.rb)。它从环境变量读取 `DEVICE_VENDOR`、`DEVICE_HOST`、`DEVICE_USERNAME`、`DEVICE_PASSWORD` 和 `TFTP_HOST`；`TFTP_SOURCE_FILE`、`TFTP_PATH`、`TFTP_VRF` 分别指定源文件、目标文件和设备 VRF。

只需在内存中采集配置时，调用 `device.running_config`；它返回 `Result`，`result.value!` 返回清理后的文本，失败时抛出对应错误。

配置采集统一由 `device/running_config` 提供，厂商差异位于 `vendor/<厂商>/running_config`。
旧 `operations/running_config`、TFTP / 拓扑厂商转发路径及 `engine/base` 等设备转发入口已移除；
自定义扩展请按[加载入口与迁移表](docs/architecture.md#加载入口与厂商策略)使用当前路径和常量。

子类可覆盖 protected 的 `login_interactions`、`confirmation_interactions`，通过 `super` 取得档案中的交互数组再追加规则。原 `login_dialogues`、`confirmation_dialogues` 已改名，不保留别名；这两个钩子仍不属于应用层公开调用入口。

配置采集默认屏蔽日志和错误诊断中的配置正文，包括 debug/raw 日志和外部 logger；返回的配置、步骤输出和备份内容保持完整。调用方应按敏感数据保管这些业务结果。

## TextFSM 解析

`parse_command` 执行一条命令，再按厂商和命令选择 TextFSM 模板。内置索引覆盖 Cisco IOS 的 `show ip interface brief`，以及拓扑发现使用的 CDP/LLDP 命令：

```ruby
Net::Connector.open(:cisco_ios, host: "192.0.2.10", username: "admin",
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  interfaces = device.parse_command("show ip interface brief")
  puts interfaces.first.fetch("INTERFACE")
end
```

`parse_config` 采集运行配置，要求显式指定模板。内置 Cisco IOS 模板只提取接口名称和描述，并非完整配置模型：

```ruby
interfaces = device.parse_config(template: "cisco_ios_running_config_interfaces.textfsm")
```

两种方法都返回由模板字段名组成的哈希数组；匹配不到记录时返回 `[]`。模板缺失或无效会抛出 `ParsingError`，设备命令失败则保留原始连接器错误。可用 `template:` 指定外部模板，或用 `template_dir:` 指定含 `index` 的模板目录。每次解析使用独立解析器，批量任务之间不共享状态。已有本地备份也可离线解析：

```ruby
saved = Net::Connector::Storage::SavedConfig.new(directory: "/var/backups")
rows = saved.parse(host: "192.0.2.10", template: "/path/to/template.textfsm")
```

解析默认严格检查 UTF-8 字节，包括终端控制符处理前的原文和处理后的文本；非法字节会抛出 `ParsingError`（`code: :invalid_output_encoding`），不会转成替换文本继续生成记录或拓扑计划。库不猜测或自动转换其他编码，原始结果、备份和离线导出保持原字节。Netdisco 入口及纯文件导出不加载 TextFSM，实际解析时才加载。

## 邻居发现与接口描述

`neighbors` 在 Cisco IOS/NX-OS 上查询 CDP，在 H3C、H3C 无线、山石和 PAN-OS 上查询 LLDP。记录包含 `local_interface`、`neighbor_name`、`neighbor_interface`、`chassis_id` 和 `protocol`。H3C 会按表头选择不同列顺序的模板；未知输出会抛出 `ParsingError`，不会误判为空表。`interface_descriptions` 从运行配置读取当前描述，Radware 则从配置转储读取端口名称。

```ruby
Net::Connector.open(:h3c, host: "192.0.2.10", username: ENV.fetch("DEVICE_USERNAME"),
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  plan = device.plan_interface_descriptions
  plan.changes.each { |change| puts "#{change.interface}: #{change.old_description.inspect} -> #{change.new_description.inspect}" }
  puts plan.commands.join("\n")
  # 核对将要下发的命令，并完成操作审批。
  result = device.apply_interface_descriptions(plan, confirmed: true)
  result.value!
end
```

默认描述为 `To <邻居名称> <邻居接口简称>`。接口缩写默认开启并保留大小写：`ethernet1/1` 变为 `eth1/1`，`Ethernet1/1` 变为 `Eth1/1`，`GigabitEthernet1/0/1` 变为 `Gi1/0/1`；未知形式保持原样。原始邻居记录、计划证据和本机下发接口名不会被缩写。`abbreviate: false` 关闭缩写，`lowercase: true` 才会转为小写；也可传入代码块自行生成完整描述。公共纯函数是 `Net::Connector::InterfaceDescription.format`。

规划会拒绝歧义邻居、缺少对端身份、不安全文本和无法识别的输出。下发必须传 `confirmed: true`，操作会再次读取邻居和旧描述；证据变化在写入前抛出 `DeviceError`，其 `code` 为 `:stale_plan`。IOS/NX-OS、H3C 和山石采用“修改 → 退出配置视图 → 读回 → 保存”的顺序；读回不匹配返回 `:description_unconfirmed`，解析不完整或查询命令不符合审批时也不会保存。

`plan.commands` 现在包括读回命令，旧版计划必须重新生成、审核；执行仍返回 `Result`，保留修改、读回及保存阶段已经完成的步骤。只有设备提供明确保存完成行才成功，保存超时、失败或只有提示符会返回 `:persistence_unconfirmed`，此时描述可能已生效，不能自动重放或回滚。现场下发前仍应按设备固件核对命令与回显。

PAN-OS 的自动描述计划及改写暂不提供，`supports?(:interface_description_changes)` 为 false，入口在设备 I/O 前抛出 `:candidate_isolation_unavailable`。候选配置的归属、验证及提交需要经目标固件实验确认的独立流程；目前可继续只读查询邻居和描述。Radware 支持读取端口名称，但不提供邻居发现或自动改写，其 `neighbors` 返回 `:neighbor_discovery_unsupported`。

PAN-OS 在导出前后检查候选配置差异，并拒绝 XML 或非 set 格式输出，避免将未提交配置误作运行配置。

## 命令脚本与自动交互

```ruby
script = Net::Connector::Script.parse(<<~CLI, name: "change-123")
  # 独立成行的注释会被忽略。
  configure terminal
  interface GigabitEthernet1/0/1
  description uplink
  end
CLI

result = device.execute_script(script) do |step|
  puts "#{step.command.text}: #{step.duration.round(2)} 秒"
end

if result.failure?
  warn "#{result.error.code}，阶段 #{result.error.phase}"
  warn "失败前已完成 #{result.steps.size} 条命令"
end
```

`execute_command` 执行一条命令；`execute_script` 接收 `Script` 或命令数组；`Script.load(path)` 读取脚本文件。所有命令在设备 I/O 前校验，后续步骤失败时仍保留已完成结果，库不会自动重放命令。`save_config` 显式执行厂商保存命令，普通脚本不会自动保存。

创建连接器时可设置 `max_script_output_bytes: 8 * 1024 * 1024`，限制每个脚本及其追加查询累计收到的原始响应字节；默认 `nil` 保持原有完整输出行为。达到上限后不再发送下一命令，当前响应超过上限时保留刚完成的步骤并返回 `ScriptOutputLimitExceeded`（`code: :script_output_limit_exceeded`）。命令可能已经执行，不会自动重试。原有 `max_output_bytes` 继续限制单次读取响应；累计预算不是进程内存上限，详细计数规则见架构文档。

厂商档案处理分页和常见确认提示。特定命令可给 `execute_command` 传入 `interactions: [Net::Connector::Interaction.new(/Token:\z/, ->(_) { "value\n" }, sensitive: true)]`。敏感命令及交互会暂停回显日志并在错误中脱敏；若普通命令文本包含秘密，必须显式标记 `sensitive: true`。

命令文本安全、输出可能包含秘密时，使用 `device.execute_command("show running-config", output_sensitive: true)`。该标记保护响应及其准备、后处理、回调异常，保留安全命令文字；不会改写 `Result` 的业务输出。`running_config` 自动启用此保护，手写脚本的默认值仍为 `false`。

## 连接与日志设置

连接参数 `on_event: ->(event) { ... }` 接收不可变、已脱敏的 `Log::Event`，可与日志文件或应用 logger 共用；按 `log_level` 过滤，独立于应用 logger 的阈值。回调同步执行，应保持简短；异常按日志故障处理，不会静默吞掉。它不提供未脱敏的配置正文。

`examples/backup.rb` 和 `examples/backup_tftp.rb` 默认全量备份符合筛选条件的设备，并在终端原地刷新两行进度（登录、采集、排队、成功和未完成数，以及耗时、平均吞吐、预计剩余时间）；失败单独输出，结束后显示汇总和报告路径。重定向时每 25 台输出一次进度，避免刷屏。`--verbose` 显示逐条登录和命令事件，`--json` 才在 STDOUT 输出 JSON；完整计划和结果始终保存在批次目录。`NC_PROGRESS=0` 关闭人类进度。百分比表示任务完成比例，不是成功率。

```sh
ruby examples/backup.rb             # 全量，默认并发 4
ruby examples/backup.rb --sample 3  # 每厂商最多 3 台
ruby examples/backup.rb --verbose  # 详细命令过程
ruby examples/backup.rb --json > result.jsonl
ruby examples/backup.rb --concurrency 10 --username backup-user --ask-password
```

批量示例支持 `--concurrency`（1 至 50）、`--username`、`--password`、`--enable-password`、`--netdisco-url`、`--netdisco-username`、`--netdisco-password`、`--directory` 和 `--config`。命令行优先于环境变量与 YAML；显式设备凭据逐字段覆盖对应厂商凭据。指定 Netdisco 用户名或密码时不再沿用环境中的 API key。密码可使用 `--ask-password` / `--ask-netdisco-password` 隐藏输入，避免命令行密码进入 shell 历史或进程参数；自动化仍可用环境变量或原有 `--stdin-credentials`。`--config` 与 `--directory` 的相对路径基于项目根目录。


`Configuration` 支持 `protocol: :ssh`（默认）或 `:telnet`，以及端口、超时、输出大小、`log_file`、`logger`、`log_format`、`log_level` 和 `known_hosts` 等参数。文本日志使用 Ruby 标准库 `Logger`，记录毫秒时间、级别、设备、中文说明和完整事件字段。`:info` 包括连接、登录、命令响应、脚本处理和 TFTP 结果；`:debug` 增加逐行脱敏回显；`:warn`、`:error` 只保留相应级别。`:raw` 文件只写经过现有敏感保护的设备字节，不添加事件字段。

`log_file` 只接受普通文件，拒绝符号链接、FIFO 和设备文件；应用管理的输出流可通过 `logger` 注入。命令已经完成后若日志或事件回调失败，失败结果仍保留完成步骤，TFTP 错误仍携带已确认的设备回执；调用方不能据此自动重放命令。

每次连接生成 `session_id`，每条实际发送的命令分配 `command_id`；日志还包含 `operation`、`phase`、脚本 `source` / `line`、`duration_ms`、`response_bytes` 和失败 `code`。`command_complete` 的 `response_received` 只表示收到了提示符；`operation_complete` 覆盖脚本准备、执行及后处理，不替代 TFTP 服务端核验或设备持久化证据。普通自定义事件使用 `device.log_event("audit", level: :info, count: 2)`。

可注入 `logger: Rails.logger` 或普通 `Logger`。有效级别取 `log_level` 与调用方**当前**级别中较严格的一项；连接器不修改它的级别、formatter 或 progname，也不关闭它。消息是已脱敏且冻结的 `Net::Connector::Log::Event`，`to_s` 供文本显示，`to_h` 供应用 formatter 输出 JSON：

```ruby
require "net/connector"
require "json"
require "logger"
require "time"

logger = Logger.new($stdout)
logger.formatter = lambda do |severity, time, program, message|
  fields = message.is_a?(Net::Connector::Log::Event) ? message.to_h : { message: message.to_s }
  "#{JSON.generate(time: time.iso8601(3), severity: severity, program: program, **fields)}\n"
end
# 将 logger: logger 传给 Net::Connector.build / open。
```

事件字段接受字符串、符号、整数、有限浮点数、布尔和 nil；复杂对象统一隐藏，不展开对象内容。事件名、字段名和值经过校验/脱敏，会话与命令标识不可由自定义字段覆盖。敏感命令或配置处理期间，自定义事件的名称和载荷整体隐藏，避免钩子把未登记的配置秘密写进日志。更多边界见[架构文档](docs/architecture.md)。

主机密钥策略默认为 `:strict`；`:accept_new` 接受首次连接的密钥；`:replace` 需要显式 `known_hosts` 文件。`telnet_fallback` 和 `legacy_ssh` 默认关闭，只在已识别的连接失败时使用。外部命令以参数数组执行，不经 shell。Telnet 不提供 SSH 加密，只应在可信管理网络启用。设备授权和变更审批由调用方负责。

## Netdisco 清单与批量备份

`Net::Connector::Netdisco` 读取并验证完整清单，再将支持的记录映射到连接器，使用有上限的工作线程执行备份。Netdisco 只提供清单字段；设备凭据来自环境变量或调用方提供的解析器。清单会在连接任何设备前完成校验；不支持、被过滤、重复、缺少凭据、失败，以及保存成功但关闭失败的结果分别保留。

每次 `Client#devices` 默认限制单响应 16 MiB、累计响应 128 MiB、去重前 100,000 条记录、10,000 页和 300 秒总期限。认证、分页及兼容查询共用这些预算；默认 HTTP 客户端逐块计数，超限会关闭连接并抛出带稳定 `code` 的 `Client::Error`，Fleet 不会执行半份清单。这些默认值是可调整的设计起点，不是实测容量。可注入 `requester: ->(uri, request)`；该回调只能在回调返回后检查正文和期限，回调自身的阻塞及内存用量由注入方控制。

推荐使用 HTTPS，标准证书验证保持开启。`allow_insecure_http` 默认为 `true`；设为 `false` 可在发请求前拒绝 HTTP，YAML 中对应 `netdisco.allow_insecure_http: false`。HTTP 会明文传输登录凭据和 API key，迁移时应先提供可验证的 HTTPS 端点。

`Fleet#plan_backup` 和 `Fleet#plan_tftp_backup` 从同一份清单生成计划。把计划传给 `backup_all(plan:)` 或 `tftp_backup_all(plan:)`，可使预览与执行选择同一批设备；计划与清单不符时会拒绝执行。单台设备异常或结果回调失败不会阻止其他设备。`batch.summary` 包含总数、成功、失败、部分成功、跳过、具体状态和逐台结果。部分成功包括已保存但关闭失败，以及本地文件已替换但目录同步或收尾失败；后者保留 backup 并标为 `saved_with_error`。TFTP 的 `reported_uploaded` 仅代表设备报告上传，不代表服务器文件已核验。

本地 `backup(path:)` 用 SHA-256 比较新旧配置，`backup.change` 返回 `:created`、`:changed` 或 `:unchanged`；内容未变且权限、文件身份正常时保留修改时间。这不补验历史写入的断电持久性。`backup_all` 的 `on_change:` 仅在新建或更改文件保存后触发；`on_start:` 和 `on_result:` 观察每台已尝试设备。回调异常记录在 `batch.callback_errors`，不丢弃设备结果。每项结果包含开始、结束和耗时。TFTP 无法比较服务器文件，因此没有 `change`，也不触发变更通知。

每批默认由 `ResultStore::Json` 写入私有 JSON 报告，路径见 `batch.report_location`。调用方如有数据库仓储，可传 `ResultStore::Database.new(repository: YourModel)`；仓储需实现 `create!(attributes)`。`result_store: nil` 表示由调用方自行持久化。报告失败保留在 `batch.report_error`，同时使 `batch.success?` 为假。若报告已替换但目录同步失败，仍保留位置；离线 `--export --output` 遇到同类错误返回 2，并说明文件已经提交。

Fleet 统一返回 `Netdisco::Report`，JSON 的 `schema_version` 固定为 `2`。报告包含 `policy`、`policy_success`、清单覆盖和受控诊断；`success?` / `status` 表示严格完成情况，`policy_success?` 表示所选成功策略。任务耗时使用单调时钟，UTC 开始/结束时间独立保留。`report.batch` 是原始执行快照；手工构造的 Batch 可用 `batch.build_report(policy: :selected)` 生成报告，不会再次执行设备或重写文件。

`success_policy: :selected` 要求至少一台设备成功，其他记录只因 `filtered` 或 `sample_limit` 跳过，而且没有部分成功、回调或报告错误。缺少凭据、重复地址、无效地址、未知厂商、目标冲突和未知状态均会阻止成功。`coverage.complete` 只表示每条清单记录都已尝试任务；失败任务也计入尝试，不能据此判断配置已保存。自定义 `ResultStore#write(report, directory:)` 始终接收 Report，并通过 `summary` 获取统一 JSON 结构。

外部构造的计划也必须把同一管理地址的全部条目标记为 `duplicate_host` 并跳过，不能通过采样恢复其中一条的执行资格；IPv6 的等价写法视为同一地址。只需汇总时使用 `report.statistics`，它返回 `summary` 除 `devices` 外的字段，不生成设备明细，也不缓存调用方持有的批次容器。

```sh
export NETDISCO_URL=https://netdisco.example/netdisco
export NETDISCO_USERNAME=inventory-reader
export NETDISCO_PASSWORD='replace-me'
export NC_DEVICE_USERNAME=backup-user
export NC_DEVICE_PASSWORD='replace-me'
export NC_BACKUP_DIRECTORY=/var/backups/network
export NC_CONCURRENCY=4
```

```ruby
require "net/connector/netdisco"

fleet = Net::Connector::Netdisco::Fleet.new
plan = fleet.plan_backup
puts plan.selected.map(&:host)
batch = fleet.backup_all(plan: plan, on_change: ->(outcome) {
  puts "#{outcome.device.host}: #{outcome.backup.change}"
})
puts batch.counts
puts batch.summary.slice(:succeeded, :failed, :partial, :skipped)
puts batch.report_location
batch.outcomes.each do |outcome|
  puts "#{outcome.device.source_ip}: #{outcome.status} #{outcome.backup&.path}"
end
exit 1 unless batch.success?
```

gem 安装后的命令为 `net-backup`；源码入口为 `bin/net-backup`，可在项目目录运行 `bundle exec bin/net-backup --help`。原命令 `net-connector-backup` 已改名。

命令行程序 `net-backup` 的 YAML 文件只允许非敏感设置；Netdisco 和设备凭据留在环境变量中。常用环境变量优先于 YAML，复杂参数只通过 YAML 或 CLI 设置。批量示例也支持 `NC_CONFIG`，可从 [完整配置示例](examples/backup.yml) 开始。只有传入 `--config FILE` 或设置 `NC_CONFIG` 时才加载文件：

```yaml
netdisco:
  url: https://netdisco.example/netdisco
  page_size: 500
  max_response_bytes: 16777216
  max_inventory_bytes: 134217728
  max_devices: 100000
  max_pages: 10000
  inventory_timeout: 300
  allow_insecure_http: false
backup:
  directory: /var/backups/network
  concurrency: 4
inventory:
  include_vendors: [h3c, huawei, cisco_ios]
  host_overrides:
    192.0.2.7: h3c_wireless
ssh:
  host_key_policy: strict
  max_script_output_bytes: null # 可选正整数字节数；null 保持不限制累计值。
tftp:
  server: 192.0.2.10
  vrfs:
    cisco_nxos: management
```

```sh
net-backup --config config.yml --show-config
net-backup --config config.yml --plan --host 192.0.2.7
net-backup --config config.yml --host 192.0.2.7
net-backup --config config.yml --tftp --plan
net-backup --config config.yml --tftp --all
net-backup --config config.yml --export 192.0.2.7 --output ./exports/device.cfg
```

### PostgreSQL 联机查询

设置 `netdisco.source: postgres` 可以直接从数据库查询清单，继续使用同一套 Fleet、规则、计划和备份流程。库不内置表名、SQL 或业务筛选条件；必须提供查询，可直接修改 [YAML 示例](examples/inventory_sql.yml)：

```yaml
netdisco:
  source: postgres
  query: |
    SELECT host(ip) AS ip, name, dns, vendor, os, model, os_ver, serial
    FROM device
    WHERE vendor = $1
    ORDER BY ip
  query_params: [H3C]
```

查询必须返回唯一命名的 `ip` 列；可选列为 `name`、`dns`、`vendor`、`os`、`model`、`os_ver`、`serial`，其他列会丢弃。自定义表、视图、JOIN 和只读 CTE 均可用列别名适配这一契约。PostgreSQL 的 `inet` 字段建议用 `host(ip) AS ip` 去除前缀长度；筛选及排序由 SQL 决定。参数按数组顺序绑定 `$1`、`$2`，支持字符串、数字、布尔和 null，不做字符串插值或环境变量展开。

数据库连接信息只从进程环境读取，沿用 [Netdisco 官方环境变量命名](https://github.com/netdisco/netdisco/wiki/Environment-Variables)。`HOST`、`NAME`、`USER`、`PASS` 必填；HTTP 地址、API key 和设备登录凭据不是清单查询的前置条件：

```sh
export NETDISCO_DB_HOST=database.example
export NETDISCO_DB_NAME=netdisco
export NETDISCO_DB_USER=inventory-reader
export NETDISCO_DB_PASS='replace-me'
export NETDISCO_DB_SSLMODE=verify-full
export NETDISCO_DB_SSLROOTCERT=/etc/net-connector/database-ca.crt

net-backup --config examples/inventory_sql.yml --show-config
net-backup --config examples/inventory_sql.yml --plan
# 覆盖查询参数；实际备份仍需设置 NC_DEVICE_* 凭据。
net-backup --config examples/inventory_sql.yml --plan --query-params '["Cisco"]'
```

SQL、参数和来源也可分别通过 `--query SQL`、`--query-params JSON`、`--source postgres` 覆盖 YAML，不再从环境变量读取。SQL 和参数属于可公开配置，会出现在 `--show-config` 中；数据库密码只放在连接环境变量中。连接信息不进入策略快照、计划、报告或 `inspect`。已有 Fleet 每次重新查询时读取最新连接凭据；传入已有 `plan:` 执行时不会重新查询。

客户端通过 `pg` 驱动执行只读事务，使用参数化游标分批取数，并在每批启用单行读取。PostgreSQL 原生解析拒绝多条语句，写入和锁定查询会失败；查询账户应仅授予所需表/视图的 SELECT 权限，只读事务不能替代账户权限隔离。驱动只在实际查询时加载，HTTP 和离线导出路径不加载它。

数据库查询复用现有清单预算：`page_size` 控制每次 FETCH 的行数，`max_pages` 限制 FETCH 次数，`max_devices` 在去重前计数；字节预算统计返回列名与文本值，包含最终丢弃的列。字节检查发生在 libpq 解码一行之后，不能限制单个超大字段在驱动内部的瞬时内存。连接、查询和全部 FETCH 共用总期限，同时设置数据库 statement_timeout。任一查询错误、超时或超限均关闭连接并丢弃整份清单，不连接设备；错误消息不输出原始 SQL、参数或数据库响应。建议只选所需字段，并提供明确的 ORDER BY 保持采样顺序稳定。

### 计划与执行

`--plan` 只拉取并验证清单；`--host` 选择一个管理地址；`--tftp` 默认每厂商最多选择五台，`--all` 选择所有就绪设备。本地备份默认选择所有就绪设备，可用 `--limit-per-vendor` 限制。`--show-config` 只输出有效的非敏感设置，不访问 Netdisco。CLI 会拒绝未知 YAML 字段、Ruby 对象标签及配置中的凭据。`--export IP` 只离线读取规范化管理地址对应的 `<IP>.txt`；默认原样写到标准输出，指定 `--output` 后以 `0600` 权限原子写文件。导出的配置仍是敏感数据。

CLI 的计划与批次摘要使用 JSON。默认 `--success-policy strict` 使用严格规则：非空清单且全部成功、回调及报告正常时为 `0`；空清单或有跳过、部分成功、失败时为 `1`；清单或配置错误为 `2`。`--host` 未在清单中找到也返回 `2`。由于其他清单记录会标记为过滤，默认单主机备份成功时批次退出码仍可能是 `1`；应查看 JSON 中的 `succeeded`、`skipped` 和逐台 `status`。

显式使用 `--success-policy selected` 后，CLI 按上述 selected 规则决定退出码，保留严格的 `status: incomplete` 与跳过计数，另列 `policy_success`。例如 `net-backup --config config.yml --host 192.0.2.7 --success-policy selected`。成功策略由本次 CLI/API 参数指定，不改变已批准的清单选择，也不触发重试。

本地批量示例和 TFTP 批量示例默认全量；显式 `--sample N`、`NC_SAMPLE_PER_VENDOR` 或 YAML `backup.limit_per_vendor` 才限制每厂商数量（示例允许 1 至 5）。优先级为命令行抽样 > 环境变量 > YAML。并发默认 4，可用 `NC_CONCURRENCY` 覆盖。两类示例在备份目录下创建唯一批次目录。TFTP 批量示例在可访问服务器目录时使用 hostname-ip 远端文件名并逐批归档；无法访问服务器目录时使用带批次标识的远端文件名，避免覆盖旧文件；上传完成与服务器文件验证是不同状态。

全量 TFTP 计划保存为 `plan.json`。目标文件名通常为 `<设备名>-<IP>.cfg`，Radware 用 `.tgz`，山石用 `.dat`。可访问本机 TFTP 服务器目录时，批量示例直接使用 `<设备名>-<IP>.<扩展名>` 上传，并在服务器的 `archive/<批次>/` 与本地 `<批次目录>/tftp/` 各保留一份；上传前已有的同名文件先保存到新归档目录的 `previous/`。无法访问服务器目录时，远端文件名增加东八区批次标识及同秒序号，避免覆盖旧文件；实际文件名见 `summary.json` 的 `remote_path`。计划仍检查同批目标名冲突。PAN-OS 固定使用 `running-config.xml`，还要求 `Sent ... bytes` 完成行；为避免下次上传覆盖它，运行批量示例时必须能访问本机 TFTP 服务器目录，否则该设备会明确失败且不会发起上传。H3C 从 `display startup` 发现源文件，可用 YAML `tftp.h3c_source_file` 覆盖；华为默认 `flash:/startup.cfg`。Nexus 9000 默认 VRF 为 `management`，山石为 `mgt-vr`；YAML `tftp.vrfs` 接受按厂商键配置的映射。山石命令在 `vrouter` 参数后追加唯一的 `.dat` 文件名；直接调用山石连接器且不指定 `path:` 时，由设备生成文件名并在结果中返回。通过 `--tftp-root DIR` 或 `TFTP_ROOT` 指定本机或已挂载的服务器目录时，批量示例在每台设备完成后核验实际回执路径、非空文件、修改时间和 SHA-256，并立即保存两份历史文件；报告的 `local_file` 和 `server_archive_file` 分别指向本地批次副本和服务器归档副本。核验或归档失败不会报告成功。未提供本机目录时，可命名设备仍使用不覆盖旧文件的远端文件名，回执保留为 `device_reported`，本地批次不包含配置副本。默认示例使用 `selected` 策略；要求服务器文件核验时使用 `--success-policy verified`，并提供本机服务器目录。可运行 `ruby examples/review_tftp.rb <批次目录>`，根据会话日志复核剩余失败，而不改写原始结果。日志、`events.jsonl` 和逐台结果均以私有权限保存。

批量 TFTP 源文件通过 YAML `tftp.h3c_source_file`、`tftp.h3c_wireless_source_file`、`tftp.huawei_source_file` 设置。源文件是设备上的路径，需符合连接器校验规则。

本地配置备份写到 `<目录>/<IP>.txt`，IPv6 的 `:` 转成 `_`。设备改名不改变文件名或比较基线；只读取该规范路径，缺失时创建新备份。其他名称的文件不参与查找或哈希比较。Fleet 和离线读取拒绝符号链接及非普通文件。文件原子替换为 `0600`，新目录权限为 `0700`。批次在当前进程执行，需要定时任务或持久队列时由调用方安排；失败命令不会自动重试。


| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `NETDISCO_URL` | HTTP 模式必填 | Netdisco 服务根地址，可包含租户路径 |
| `NC_CONFIG` | 未设置 | CLI / 批量示例的非敏感 YAML 配置文件 |
| `NETDISCO_USERNAME`, `NETDISCO_PASSWORD` | 未提供 API 密钥时必填 | 清单 API 登录 |
| `NETDISCO_API_KEY` | 未设置 | 直接使用已有 API 密钥 |
| `NETDISCO_DB_HOST`, `NETDISCO_DB_NAME` | PostgreSQL 模式必填 | 数据库主机或 Unix socket 目录、数据库名 |
| `NETDISCO_DB_USER`, `NETDISCO_DB_PASS` | PostgreSQL 模式必填 | 仅从环境注入的数据库用户名、密码 |
| `NETDISCO_DB_PORT` | libpq 默认 `5432` | PostgreSQL 端口 |
| `NETDISCO_DB_SSLMODE`, `NETDISCO_DB_SSLROOTCERT` | libpq 默认 | TLS 模式、CA 文件；远程连接建议 `verify-full` |
| `NETDISCO_DB_CONNECT_TIMEOUT` | 未单独设置 | 可选正整数秒；连接始终受清单总期限限制 |
| `NC_DEVICE_USERNAME`, `NC_DEVICE_PASSWORD` | 未设置 | 设备登录默认凭据 |
| `NC_<VENDOR>_USERNAME`, `NC_<VENDOR>_PASSWORD` | 未设置 | 单厂商凭据，例如 `CISCO_IOS` |
| `NC_BACKUP_DIRECTORY` | `./backups` | 备份及默认报告目录 |
| `NC_CONCURRENCY` | `4` | 并发设备数，范围 1 至 50 |
| `NC_PROTOCOL` | `ssh` | 默认连接协议，可按厂商覆盖 |
| `NC_KNOWN_HOSTS`, `NC_HOST_KEY_POLICY` | 系统主机记录、`strict` | SSH 主机密钥设置 |
| `NC_LOG_DIRECTORY` | 未设置 | 逐台会话日志目录 |
| `NC_LOG_LEVEL` | `info` | `debug`、`info`、`warn`、`error` 日志级别 |

环境变量前缀统一为 `NC_`；`NETDISCO_*` 仅保留服务地址、认证和数据库连接设置。旧 `NET_CONNECTOR_*` 及已移除的复杂环境变量会报迁移错误，不会静默忽略。凭据保持在环境变量中，YAML 不接受密码。

| 其他常用变量 | 用途 |
| --- | --- |
| `NC_SAMPLE_PER_VENDOR` | 可选抽样上限；示例不设置时全量，设置时允许 1 至 5 |
| `NC_PROGRESS` | 批量示例实时进度，默认 1；0 关闭 |
| `NC_ENABLE_PASSWORD`, `NC_<VENDOR>_ENABLE_PASSWORD` | 可选提权密码 |
| `TFTP_HOST`, `TFTP_ROOT` | TFTP 地址、示例验证用的本地服务器目录 |

将原来的环境配置移到 YAML：清单预算放在 `netdisco`；过滤、厂商/主机映射及规则放在 `inventory`；脚本输出预算与厂商协议放在 `ssh`；VRF 和源文件放在 `tftp`。例如：

```yaml
inventory:
  include_vendors: [h3c, cisco_nxos]
  device_rules:
    - vendor: Cisco
      model_prefix: N9K
      connector: cisco_nxos
ssh:
  vendor_protocols:
    h3c: ssh
  max_script_output_bytes: 16777216
```


`Fleet` 每次规划或执行前通过 `Settings#snapshot(mode:)` 固定非敏感设置，包括筛选规则、目录、并发、协议、主机密钥、日志、TFTP 参数和清单预算。执行中修改 ENV 不改变当批策略；再次调用会读取新值。CLI 一次调用的规划与执行共用策略，优先级为 CLI > 常用环境变量 > YAML > 默认值。`Settings#validate!(mode:)` 复用连接配置及 Planner 的枚举和范围规则；`--show-config` 会拒绝非法设置，`--export` 只验证离线目录，不要求清单地址或认证。

每台任务开始时仍读取设备凭据，`Settings.from_file` 也保留轮换能力。纯策略快照不保存密码、API key 或凭据解析器。需要让多次 API 调用共用策略时，可传 `Settings.new.for_run(mode: :backup)`。自定义 `credentials:` 解析器仍可逐设备返回连接设置，它显式给出的选项优先于批次默认值，由调用方负责一致性；注入的 `client:` 生命周期也由调用方管理。传入 `plan:` 的执行不会重新拉取或筛选已批准清单。`fleet.devices` 可在不连接设备时检查映射。

## 开发与验证

```sh
bundle install
script/ci
```

CI 在 Linux 和 macOS 上覆盖 Ruby 3.2、3.3、3.4、4.0。`script/ci` 扫描源码与可用 Git 历史中的敏感数据，执行 Ruby 与工作流 lint、完整测试，并验证已构建 gem 的隔离安装和本地 PTY 烟测；不连接真实网络设备。首次运行需下载固定校验和的 Gitleaks 与 actionlint。

`bundle exec rake test` 报告当前测试进程的行、分支覆盖率和未加载文件清单。核心引擎、脱敏与错误处理（含 `Redactor`）、批量工作线程分别要求行和分支覆盖率均达到 80%，关键文件没有覆盖率数据也会失败；该门槛同时阻止 CI 和发布预检通过。`bundle exec rake lint` 检查 Ruby 代码，并对 `engine/`、`netdisco/` 限制方法长度（40）和 ABC 复杂度（60）。`bundle exec rake security:check` 扫描敏感数据，`bundle exec rake release:check` 执行完整预检。构建产物和脱敏扫描报告保存在被忽略的 `tmp/` 下。

参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)，漏洞报告见 [SECURITY.md](SECURITY.md)。实现注释和主要文档使用中文，欢迎中文或英文的问题与 PR。

真实凭据应放在环境变量和版本库外的本地配置中。检查范围、依赖政策和忽略规则见[验证文档](docs/VERIFICATION.md)，发布流程见[发布文档](docs/RELEASING.md)。

备份示例通过 `examples/boot.rb` 读取项目根目录 `.env`，不会自动切换依赖或注入源码路径。直接 `ruby examples/backup.rb`（或在 `examples/` 中执行 `ruby backup.rb`）使用已安装的 gem；修改库后必须重新构建并安装，开发源码验证则使用 `bundle exec ruby examples/backup.rb`。示例中的相对备份、日志路径统一基于项目根目录；进程中显式传入的 `NC_CONFIG` 路径按启动目录解析。

清单自动识别保留显式主机映射、设备规则和厂商覆盖的优先级。若厂商标签陈旧，而 `os: Comware` 与 `model: H3C ...` 同时确认 H3C，则自动使用 H3C 连接器；`H3C WX...` / `H3C AC...` 使用无线连接器。仅型号片段或操作系统单项不会覆盖其他厂商。

备份部署示例 `.env.example` 使用 `NC_HOST_KEY_POLICY=accept_new`：首次连接自动登记到 OpenSSH known_hosts，已有密钥变化仍拒绝连接。`--host-key-policy strict|accept_new` 可覆盖本次策略，`--known-hosts FILE` 指定持久保存位置；不应删除密钥文件，否则会丢失历史身份记录。库本身默认仍为 strict。

设备密钥变化也需自动更新时，使用 `--host-key-policy replace --known-hosts FILE`，或设置 `NC_HOST_KEY_POLICY=replace` 与 `NC_KNOWN_HOSTS`。文件必须显式指定；只在主机密钥变化错误时删除该设备旧记录并重连一次，不重放设备命令。建议使用备份任务专用的持久密钥文件。

进度每秒更新一次心跳；设备无新输出时仍显示耗时，超过 10 秒的最久任务显示地址、阶段与任务耗时。预计剩余时间按已完成任务的平均吞吐计算，前五台完成前显示“估算中”，异构设备和末尾慢任务会使估算波动。终端事件刷新最多约每秒五次，退出或异常时回收显示线程；结束按错误代码汇总未完成任务。

本地批量示例将配置写为 `hostname-ip.txt`（名称取 Netdisco name/dns），空名称使用 `unnamed`，特殊字符清理，IPv6 冒号替换为下划线。批次目录固定使用 UTC+8 的 `YYYY-MM-DD_HH-mm-ss`，同秒冲突追加 `_01` 等序号。每批包含 `plan.json`、`summary.json` 和人类可读的 `summary.txt`（时间、计数、失败分类及失败明细），报告权限为 0600。历史目录不改名；通用 Fleet/CLI 仍默认 IP 文件名，API 可显式传入 `filename_style: :hostname_ip`，该模式设备改名会改变文件路径与比较基线。

公共备份辅助接口随 gem 分发，不依赖 examples 文件：

```ruby
require "net/connector/netdisco"
netdisco = Net::Connector::Netdisco
options = netdisco::CLI::Options.parse(argv: ["--concurrency", "10"])
settings = netdisco::CLI::Options.settings(options)
client, credentials = netdisco::Connection.build(settings)
directory = Net::Connector::Storage::BatchDirectory.create("./backups")
# 获得 report 和 plan 后：
# report = netdisco::Report::Files.write(report, directory: directory, plan: plan, concurrency: 10)
```

`CLI::Options.parse` 接受 `argv/input/output/error/program`，不修改传入参数数组；帮助通过返回值 `:help` 通知调用方，非法输入抛出 `ArgumentError`。`Connection.build` 接受 `input:`，标准输入凭据仅消费一行，RUN 确认由脚本编排负责。模块不加载 `.env` 或切换目录。


批量示例由 `Netdisco::BackupRun` 统一编排，`CLI::Options.settings` 为示例和正式 CLI 共用配置覆盖入口。
示例默认 `selected`，正式 CLI 保留 `strict` 默认；两者均支持显式 `--success-policy`，退出码与报告的 `policy_success` 一致。
新示例 `summary.json` 使用标准 schema 2 的 `devices`，不再另造 `outcomes`；旧报告可继续用 `review_tftp.rb` 读取。
TFTP 的 `verification` 汇总与设备条目的 `server_file_verified` 区分上传回执和服务器文件核验，核验成功还包含 `local_file`、`server_archive_file`、`bytes`、`sha256`。
报告通过私有原子写入保存；报告保存失败会阻止成功退出，终端最终结果在报告保存之后输出。

`--stdin-credentials` 的一行 JSON 保留 `netdisco_username`、`netdisco_password`、`device_username`、`device_password` 四个字段。
清单来源为 PostgreSQL 时，前两个字段覆盖数据库用户名和密码，主机、数据库名及 TLS 参数仍由 NETDISCO_DB_* 提供；第二行 `RUN` 仍是执行设备任务的确认。

使用 `accept_new` / `replace` 时，SSH 在每个会话的临时 known_hosts 中协商，认证后通过独立锁文件合并到共享文件。
网络登录不占用共享锁；失败登录不删除原信任记录，`replace` 只替换当前主机。该同步协调本库进程，外部手工工具应避免同时改写同一文件。
认证后的合并锁另有最多 `login_timeout` 秒的等待预算，超时返回 `ConnectionError`（`code: :known_hosts_busy`），关闭会话且保留共享信任记录；此预算只约束锁等待，不是整批任务的期限。
