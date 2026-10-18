# 设备操作指南

[English](usage.md) | [返回首页](../README.zh-CN.md) | [Netdisco 批量备份](netdisco.zh-CN.md)

支持 Ruby 3.2 及以上版本和 POSIX 系统。SSH 调用本机 OpenSSH，Telnet 需要本机安装 `telnet` 并显式选择。主要依赖为 [`expect-pty`](https://rubygems.org/gems/expect-pty) 0.5.0 及以上和 [`textfsm`](https://rubygems.org/gems/textfsm) 0.2.0 及以上。

脱敏直接复用 expect-pty 从 0.5.0 起公开的 `Expect::Redactor` 接口；连接器只管理秘密作用域和配置输出的隐私策略。

运行时依赖不设置版本约束，宿主应用通过自己的 Gemfile 和锁文件选择兼容版本。正式发布依赖的安装验证使用 JSON 2。RubyGems 上 textfsm 0.2.0 仍约束 json ~> 2.0；JSON 3 使用固定 TextFSM 源码和显式依赖声明补丁单独验证，不代表公开依赖已经支持 JSON 3。开发工具及兼容测试矩阵的版本约束不影响 gem 使用者。

示例脚本通过开发依赖 `dotenv` 自动读取项目根目录 `.env`（先执行 `bundle install`），已有进程环境变量优先；库和 CLI 本身不会隐式读取 `.env`。

## 支持的设备

`device.supports?(:tftp_backup)` 等能力查询不会连接设备，只表示该连接器实现了对应操作，不代表设备权限或固件一定支持。完整能力矩阵和扩展示例见[厂商能力](architecture.md#厂商能力)。

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
| `:topsec` | 天融信 TopOS 防火墙 | `show-running nostop` | 未开放 |
| `:fortinet` | FortiGate / FortiOS | `show full-configuration` | `execute cfg save` |
| `:juniper` | Juniper Junos OS | `show configuration \| display set \| no-more` | 不隐式提交候选库 |

厂商标识仅使用上表的规范名称。厂商连接器位于 `Net::Connector` 下，例如 `Net::Connector::Vendor::H3cWireless`。

Junos 的 FTP/SCP 原生导出使用 `remote_backup(host:, path:, username:, protocol: :scp, password: nil)`，通过 `supports?(:remote_backup)` 查询。详细能力、视图及命令依据见[新增平台说明](vendors.md)。

## 登录与本地备份

```ruby
Net::Connector.open(:cisco_ios,
  host: "192.0.2.10", username: "admin", password: ENV.fetch("NC_DEVICE_PASSWORD"),
  known_hosts: "/etc/net-connector/known_hosts", host_key_policy: :strict,
  log_file: "/var/log/net-connector/router.log") do |device|
  backup = device.backup(path: "/var/backups/router-running.cfg")
  puts "#{backup.bytes} 字节，SHA-256 #{backup.sha256}"
end
```

`open` 会在代码块结束或出错时关闭会话。`backup` 在采集前取得目标路径锁，持有到比较、保存和生成原有 `Backup` 元数据对象完成；采集失败不会覆盖旧备份。同路径争用默认立即抛出 `BackupBusy`（`code: :backup_busy`），需要有限等待可传 `lock_timeout: 2`，单位为秒。直接调用 `backup`；不要在已有 `with_operation` 会话租约内调用，否则会因锁顺序返回 `SessionBusy`。

写入使用 `0600` 临时文件、文件同步、原子替换及父目录同步。替换后同步或收尾失败会抛出 `BackupPersistenceError`，`error.backup` 保留已写文件的元数据，`error.receipt` 区分 `:committed`（持久性未确认）和 `:durable`（同步已完成）。目录同步不受支持对应 `:backup_durability_unsupported`，不会静默报告持久化成功，也不会自动重做设备采集。

备份完成后若路径锁收尾失败，`BackupFinalizeError` 保留 `error.backup` 和安全的 `error.underlying_type`，错误码为 `:backup_finalize_failed`；内容未变时不会声称重新验证过文件持久性，中断仍向调用方传播。

调用方应创建并保护备份目录，运行配置可能含有设备凭据。同目录下的 `.net-connector-<摘要>.lock` 是私有的长期锁文件，正常释放不删除它。所有写入者须使用本库的锁协议；`NOFOLLOW` 不保护被外部替换的祖先目录。锁名保守合并大小写及 Unicode 等价写法，实际备份文件名不变；在区分大小写的文件系统上，这些名称也会串行。

## 设备发起的 TFTP 备份

`tftp_backup` 让设备把原生配置直接上传到 TFTP 服务器，命令和提示交互由厂商策略提供。H3C 和华为从设备文件读取源配置，例如：

```ruby
Net::Connector.open(:huawei, host: "192.0.2.20", username: ENV.fetch("NC_DEVICE_USERNAME"),
                    password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  transfer = device.tftp_backup(host: "192.0.2.30", source_file: "flash:/startup.cfg")
  puts "已上传 #{transfer.path} 到 #{transfer.server}"
end
```

示例会下发 `tftp 192.0.2.30 put flash:/startup.cfg`；可传入 `path: "site/switch.cfg"` 指定目标文件名。H3C 默认通过 `display startup` 查找保存配置；华为因型号差异需要显式指定 `source_file:`。Cisco IOS 使用交互式 `copy running-config tftp:`；Nexus 9000 默认使用 `vrf management`，可用 `vrf:` 覆盖。山石导出已保存的启动配置，Radware Alteon 生成 `.tgz` 并处理私钥及 `mansync` 提示，PAN-OS 使用固定的 `running-config.xml` 文件名。其他厂商默认使用 `<管理地址>.cfg`。

只有设备回显确认传输完成，`tftp_backup` 才返回不可变的 `TftpReceipt`。回执直接包含 `server`、实际目标 `path`、`completed_at`、`configuration_kind`、`source_file`、`format`、`requested_path`、`verification` 和 `server_sha256`。明确失败对应 `:transfer_failed`，缺少成功证据对应 `:transfer_unconfirmed`。本方法不读取服务器上的文件。TFTP 不加密配置数据，应限制在合适的管理网络中使用。

回执的当前验证等级为 `:device_reported`，服务器摘要为 `nil`。H3C 自动探测结果标为 `:startup`；H3C/华为显式文件标为 `:saved_file`，格式为 `:unknown`，不凭扩展名推断内容。山石未指定文件名时 `requested_path` 为 `nil`，`path` 保留设备生成名称。

策略先校验参数组合，再在同一次会话租约中完成源探测、上传、证据检查和收尾。上传已确认但日志或清理失败时抛出 `TftpCompletionError`，通过 `error.receipt` 保留完成事实。显式请求与实际路径不同返回 `:transfer_path_mismatch`；实际路径无法安全确认返回 `:transfer_path_unconfirmed`，此时回执的 `path` 为 `nil`。这些错误不会自动重传；Fleet 保留上传事实并标为 `reported_with_error`。

清单内的单台设备使用统一[批量入口](../examples/backup_tftp.rb)：`bundle exec ruby examples/backup_tftp.rb --host 192.0.2.20`。服务器、源文件和 VRF 在 [backup.yml](../examples/backup.yml) 中配置；凭据使用 `NC_DEVICE_USERNAME`、`NC_DEVICE_PASSWORD`。需要指定自定义远端路径时，使用上面的 `device.tftp_backup` API。

只需在内存中采集配置时，调用 `device.running_config`；它返回 `Result`，`result.value!` 返回清理后的文本，失败时抛出对应错误。

配置采集统一由 `device/running_config` 提供，厂商差异位于 `vendor/<厂商>/running_config`。
旧 `operations/running_config`、TFTP / 拓扑厂商转发路径及 `engine/base` 等设备转发入口已移除；
自定义扩展请按[加载入口与迁移表](architecture.md#加载入口与厂商策略)使用当前路径和常量。

子类可覆盖 protected 的 `login_interactions`、`confirmation_interactions`，通过 `super` 取得档案中的交互数组再追加规则。原 `login_dialogues`、`confirmation_dialogues` 已改名，不保留别名；这两个钩子仍不属于应用层公开调用入口。

配置采集默认屏蔽日志和错误诊断中的配置正文，包括 debug/raw 日志和外部 logger；返回的配置、步骤输出和备份内容保持完整。调用方应按敏感数据保管这些业务结果。

## TextFSM 解析

`parse_command` 执行一条命令，再按厂商和命令选择 TextFSM 模板。内置索引覆盖 Cisco IOS 的 `show ip interface brief`，以及拓扑发现使用的 CDP/LLDP 命令：

```ruby
Net::Connector.open(:cisco_ios, host: "192.0.2.10", username: "admin",
                    password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  interfaces = device.parse_command("show ip interface brief")
  puts interfaces.first.fetch("INTERFACE")
end
```

`parse_config` 采集运行配置，要求显式指定模板。内置 Cisco IOS 模板只提取接口名称和描述，并非完整配置模型：

```ruby
interfaces = device.parse_config(template: "cisco/show_running_config.textfsm")
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
Net::Connector.open(:h3c, host: "192.0.2.10", username: ENV.fetch("NC_DEVICE_USERNAME"),
                    password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  device.sync_interface_descriptions.value!
end
```

显式调用 `sync_interface_descriptions`，在同一连接中完成发现、修改、读回和保存，不需要处理计划或二次确认；已有描述一致时不修改、不保存。需要单独预览审批时，后端仍可使用 `plan_interface_descriptions` 与 `apply_interface_descriptions(plan, confirmed: true)`。

默认描述为 `To_<邻居名称>_<接口简称>`，例如 `To_Core-SW_Gi1/0/1`。同类接口的厂商全称、简称和大小写统一，显示文本中的空格替换为下划线。端口、拆分通道与子接口编号完整保留；原始邻居记录和本机下发接口拼写不改变。`abbreviate: false` 保留对端接口全称，`lowercase: true` 仅将对端接口简称转为小写；后端也可用代码块定制。公共纯函数是 `Net::Connector::Topology::InterfaceDescription.format`。

| 接口类型 | 厂商名称与别名 | 描述简称 |
| --- | --- | --- |
| Ethernet | `Ethernet`、`ethernet` | `Eth` |
| 1G | `GigabitEthernet`、`GE`、`Gi` | `Gi` |
| 10G | `Ten-GigabitEthernet`、`TenGigabitEthernet`、`TenGigE`、`XGE`、山石 `xethernet` / `xe` | `Te` |
| 25G | H3C `Twenty-FiveGigE` / `WGE`、Cisco `TwentyFiveGigE`、`25GE` | `Twe` |
| 40G | `FortyGigE`、`FortyGigabitEthernet`、`FGE`、`40GE` | `Fo` |
| 100G | `HundredGigE`、`HundredGigabitEthernet`、`HGE`、`100GE` | `Hu` |
| H3C 二层聚合 | `Bridge-Aggregation`、`BAGG` | `BAGG` |
| H3C 三层聚合 | `Route-Aggregation`、`RAGG` | `RAGG` |
| Cisco 聚合 | `Port-channel`、`Po` | `Po` |
| 山石聚合 | `aggregate`、`Agg` | `Agg` |

命名依据：[H3C 接口名称](https://www.h3c.com/en/d_202307/1892442_294551_0.htm)、[Cisco 接口命令](https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst9600/software/release/17-13/command_reference/b_1713_9600_cr/interface_and_hardware_commands.html)、[山石接口示例](https://kb.hillstonenet.com/en/wp-content/uploads/2016/05/Hillstone-All-Series-Device-Troubleshooting-and-Debug-Guide.pdf)。未知前缀保持原样，不猜测速率。二层与三层聚合身份保持区分；命名规则不代表设备固件已经现场验证。

规划会拒绝歧义邻居、缺少对端身份、不安全文本和无法识别的输出。独立计划应用须传 `confirmed: true`；同步和计划应用都会再次读取邻居和旧描述；证据变化在写入前抛出 `DeviceError`，其 `code` 为 `:stale_plan`。IOS/NX-OS、H3C 和山石采用“修改 → 退出配置视图 → 读回 → 保存”的顺序；读回不匹配返回 `:description_unconfirmed`，解析不完整或查询命令不符合审批时也不会保存。

`plan.commands` 现在包括读回命令，旧版计划必须重新生成、审核；执行仍返回 `Result`，保留修改、读回及保存阶段已经完成的步骤。只有设备提供明确保存完成行才成功，保存超时、失败或只有提示符会返回 `:persistence_unconfirmed`，此时描述可能已生效，不能自动重放或回滚。现场下发前仍应按设备固件核对命令与回显。

PAN-OS 的自动描述计划及改写暂不提供，`supports?(:interface_description_changes)` 为 false，入口在设备 I/O 前抛出 `:candidate_isolation_unavailable`。候选配置的归属、验证及提交需要经目标固件实验确认的独立流程；目前可继续只读查询邻居和描述。Radware 支持读取端口名称，但不提供邻居发现或自动改写，其 `neighbors` 返回 `:neighbor_discovery_unsupported`。

PAN-OS 在导出前后检查候选配置差异，并拒绝 XML 或非 set 格式输出，避免将未提交配置误作运行配置。

同一审批计划中的规范接口只能出现一次；接口缩写与全称也按同一接口判重。在新增设备 I/O 前拒绝重复审批；Fleet 应用整批计划时，在建立任一设备会话前执行相同预检。

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

`result.output` 按顺序拼接已完成步骤的原始字节，不执行字符编码转换。每次调用返回可修改的二进制字符串，修改它不会改变已冻结的步骤输出。清理后的配置使用 `result.config`；需要失败时先抛出错误，再读取成功值时使用 `result.value!`。

创建连接器时可设置 `max_script_output_bytes: 8 * 1024 * 1024`，限制每个脚本及其追加查询累计收到的原始响应字节；默认 `nil` 保持原有完整输出行为。达到上限后不再发送下一命令，当前响应超过上限时保留刚完成的步骤并返回 `ScriptOutputLimitExceeded`（`code: :script_output_limit_exceeded`）。命令可能已经执行，不会自动重试。原有 `max_output_bytes` 继续限制单次读取响应；累计预算不是进程内存上限，详细计数规则见架构文档。

厂商档案处理分页和常见确认提示。特定命令可给 `execute_command` 传入 `interactions: [Net::Connector::Interaction.new(/Token:\z/, ->(_) { "value\n" }, sensitive: true)]`。敏感命令及交互会暂停回显日志并在错误中脱敏；若普通命令文本包含秘密，必须显式标记 `sensitive: true`。

命令文本安全、输出可能包含秘密时，使用 `device.execute_command("show running-config", output_sensitive: true)`。该标记保护响应及其准备、后处理、回调异常，保留安全命令文字；不会改写 `Result` 的业务输出。`running_config` 自动启用此保护，手写脚本的默认值仍为 `false`。

## 连接与日志设置

连接参数 `on_event: ->(event) { ... }` 接收不可变、已脱敏的 `Log::Event`，可与日志文件或应用 logger 共用；按 `log_level` 过滤，独立于应用 logger 的阈值。回调同步执行，应保持简短；异常按日志故障处理，不会静默吞掉。它不提供未脱敏的配置正文。

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

事件字段接受字符串、符号、整数、有限浮点数、布尔和 nil；复杂对象统一隐藏，不展开对象内容。事件名、字段名和值经过校验/脱敏，会话与命令标识不可由自定义字段覆盖。敏感命令或配置处理期间，自定义事件的名称和载荷整体隐藏，避免钩子把未登记的配置秘密写进日志。更多边界见[架构文档](architecture.md)。

主机密钥策略默认为 `:strict`；`:accept_new` 接受首次连接的密钥；`:replace` 需要显式 `known_hosts` 文件。`telnet_fallback` 和 `legacy_ssh` 默认关闭，只在已识别的连接失败时使用。外部命令以参数数组执行，不经 shell。Telnet 不提供 SSH 加密，只应在可信管理网络启用。设备授权和变更审批由调用方负责。
