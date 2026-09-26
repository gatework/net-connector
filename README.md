# net-connector

`net-connector` 通过 SSH 或 Telnet 操作网络设备的命令行。它可以采集运行配置、保存私有备份、执行命令脚本、回答设备提示、记录脱敏会话日志，并在失败时返回结构化错误和已完成的步骤。

代码按职责组织：`engine/` 管理会话、传输、脚本、结果和日志；`device/` 提供设备入口、档案、运行配置和接口名称处理；`vendor/<厂商>/` 保存各厂商的采集、TFTP 和拓扑规则；`operations/` 实现公共业务流程；`netdisco/` 负责清单和批量编排。相同规则直接复用，设计说明见[架构文档](docs/architecture.md)。用 `require "net/connector"` 加载设备 API，用 `require "net/connector/netdisco"` 加载 Netdisco 集成；厂商规则和 TextFSM 解析器按需加载。

支持 Ruby 3.2 及以上版本和 POSIX 系统。SSH 调用本机 OpenSSH，Telnet 需要本机安装 `telnet` 并显式选择。主要依赖为 [`expect-pty`](https://rubygems.org/gems/expect-pty) 0.3.x（至少 0.3.1）和 [`textfsm`](https://rubygems.org/gems/textfsm) 0.2.x。

## 安装

```sh
gem install net-connector
```

```ruby
require "net/connector"
```

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

兼容标识 `:cisco_n9k` 和 `:paloalto`。厂商连接器位于 `Net::Connector` 下，例如 `Net::Connector::H3cWireless::Connector`。

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

`open` 会在代码块结束或出错时关闭会话。`backup` 先采集配置，再以 `0600` 权限原子替换目标文件；采集失败不会覆盖旧备份。返回值为 `Backup(path:, bytes:, sha256:, collected_at:)`。调用方应创建并保护备份目录，运行配置可能含有设备凭据。

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

只有设备回显确认传输完成，方法才返回 `TftpBackup(server:, path:, completed_at:)`。明确失败对应 `:transfer_failed`，缺少成功证据对应 `:transfer_unconfirmed`。本方法不读取服务器上的文件。TFTP 不加密配置数据，应限制在合适的管理网络中使用。

可运行[单设备示例](examples/tftp_backup.rb)。它从环境变量读取 `DEVICE_VENDOR`、`DEVICE_HOST`、`DEVICE_USERNAME`、`DEVICE_PASSWORD` 和 `TFTP_HOST`；`TFTP_SOURCE_FILE`、`TFTP_PATH`、`TFTP_VRF` 分别指定源文件、目标文件和设备 VRF。

只需在内存中采集配置时，调用 `device.running_config`；它返回 `Result`，`result.value!` 返回清理后的文本，失败时抛出对应错误。

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
saved = Net::Connector::Operations::SavedConfig.new(directory: "/var/backups")
rows = saved.parse(host: "192.0.2.10", template: "/path/to/template.textfsm")
```

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

规划会拒绝歧义邻居、缺少对端身份、不安全文本和无法识别的输出。下发必须传 `confirmed: true`，操作会再次读取邻居和旧描述；证据变化返回 `:stale_plan`。计划包含厂商保存命令，PAN-OS 使用 `commit`。执行后还会回读配置，未确认新描述时返回 `:description_unconfirmed`。脚本失败的 `Result` 保留已完成步骤。Radware 支持读取端口名称，但当前不提供邻居发现或自动改写；其 `neighbors` 返回 `:neighbor_discovery_unsupported`。现场下发前应按设备固件核对命令与回显。

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

`execute` 执行一条命令；`execute_script` 接收 `Script` 或命令数组；`Script.load(path)` 读取脚本文件。所有命令在设备 I/O 前校验，后续步骤失败时仍保留已完成结果，库不会自动重放命令。`save_config` 显式执行厂商保存命令，普通脚本不会自动保存。

厂商档案处理分页和常见确认提示。特定命令可给 `execute` 传入 `interactions: [Net::Connector::Interaction.new(/Token:\z/, ->(_) { "value\n" }, sensitive: true)]`。敏感命令及交互会暂停回显日志并在错误中脱敏；若普通命令文本包含秘密，必须显式标记 `sensitive: true`。

## 连接与日志设置

`Configuration` 支持 `protocol: :ssh`（默认）或 `:telnet`，以及端口、超时、输出大小、`log_file`、`logger`、`log_format`、`log_level` 和 `known_hosts` 等参数。文本日志使用 Ruby 标准库 `Logger`，记录本地时间、级别、设备标记和中文事件。`:info` 记录连接、登录、命令和 TFTP 结果；`:debug` 还记录脱敏回显与耗时；`:warn`、`:error` 只保留相应级别。`:raw` 文件只写设备字节，不写事件元数据。可注入 `logger: Rails.logger`，连接器不会关闭或修改调用方的日志器。

主机密钥策略默认为 `:strict`；`:accept_new` 接受首次连接的密钥；`:replace` 需要显式 `known_hosts` 文件。`telnet_fallback` 和 `legacy_ssh` 默认关闭，只在已识别的连接失败时使用。外部命令以参数数组执行，不经 shell。Telnet 不提供 SSH 加密，只应在可信管理网络启用。设备授权和变更审批由调用方负责。

## Netdisco 清单与批量备份

`Net::Connector::Netdisco` 读取并验证完整清单，再将支持的记录映射到连接器，使用有上限的工作线程执行备份。Netdisco 只提供清单字段；设备凭据来自环境变量或调用方提供的解析器。清单会在连接任何设备前完成校验；不支持、被过滤、重复、缺少凭据、失败，以及保存成功但关闭失败的结果分别保留。

`Fleet#plan_backup` 和 `Fleet#plan_tftp_backup` 从同一份清单生成计划。把计划传给 `backup_all(plan:)` 或 `tftp_backup_all(plan:)`，可使预览与执行选择同一批设备；计划与清单不符时会拒绝执行。单台设备异常或结果回调失败不会阻止其他设备。`batch.summary` 包含总数、成功、失败、部分成功、跳过、具体状态和逐台结果。部分成功表示设备已报告备份完成，但会话关闭失败。TFTP 的 `reported_uploaded` 仅代表设备报告上传，不代表服务器文件已核验。

本地 `backup(path:)` 用 SHA-256 比较新旧配置，`backup.change` 返回 `:created`、`:changed` 或 `:unchanged`；未变化文件保留修改时间。`backup_all` 的 `on_change:` 仅在新建或更改文件保存后触发；`on_start:` 和 `on_result:` 观察每台已尝试设备。回调异常记录在 `batch.callback_errors`，不丢弃设备结果。每项结果包含开始、结束和耗时。TFTP 无法比较服务器文件，因此没有 `change`，也不触发变更通知。

每批默认写入私有 JSON 报告，路径见 `batch.report_location`。调用方如有数据库仓储，可传 `ResultStore::Database.new(repository: YourModel)`；仓储需实现 `create!(attributes)`。`result_store: nil` 表示由调用方自行持久化。报告失败保留在 `batch.report_error`，同时使 `batch.success?` 为假。

```sh
export NETDISCO_URL=https://netdisco.example/netdisco
export NETDISCO_USERNAME=inventory-reader
export NETDISCO_PASSWORD='replace-me'
export NET_CONNECTOR_DEVICE_USERNAME=backup-user
export NET_CONNECTOR_DEVICE_PASSWORD='replace-me'
export NET_CONNECTOR_BACKUP_DIRECTORY=/var/backups/network
export NET_CONNECTOR_CONCURRENCY=4
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

命令行程序 `net-connector-backup` 的 YAML 文件只允许非敏感设置；Netdisco 和设备凭据留在环境变量中。环境变量优先于 YAML。只有传入 `--config FILE` 或设置 `NET_CONNECTOR_CONFIG` 时才加载文件：

```yaml
netdisco:
  url: https://netdisco.example/netdisco
  page_size: 500
backup:
  directory: /var/backups/network
  concurrency: 4
inventory:
  include_vendors: [h3c, huawei, cisco_ios]
  host_overrides:
    192.0.2.7: h3c_wireless
ssh:
  host_key_policy: strict
tftp:
  server: 192.0.2.10
  vrfs:
    cisco_nxos: management
```

```sh
net-connector-backup --config config.yml --show-config
net-connector-backup --config config.yml --plan --host 192.0.2.7
net-connector-backup --config config.yml --host 192.0.2.7
net-connector-backup --config config.yml --tftp --plan
net-connector-backup --config config.yml --tftp --all
net-connector-backup --config config.yml --export 192.0.2.7 --output ./exports/device.cfg
```

`--plan` 只拉取并验证清单；`--host` 选择一个管理地址；`--tftp` 默认每厂商最多选择五台，`--all` 选择所有就绪设备。本地备份默认选择所有就绪设备，可用 `--limit-per-vendor` 限制。`--show-config` 只输出有效的非敏感设置，不访问 Netdisco。CLI 会拒绝未知 YAML 字段、Ruby 对象标签及配置中的凭据。`--export IP` 离线读取已有 `<IP>.txt`，或唯一匹配的旧版 `<设备名>-<IP>.txt`；默认原样写到标准输出，指定 `--output` 后以 `0600` 权限原子写文件。导出的配置仍是敏感数据。

CLI 的计划与批次摘要使用 JSON。非空清单且全部成功时退出码为 `0`；空清单或有跳过、部分成功、失败时为 `1`；清单或配置错误为 `2`。`--host` 未在清单中找到也返回 `2`。由于其他清单记录会标记为过滤，单主机备份成功时批次退出码仍可能是 `1`；应查看 JSON 中的 `succeeded`、`skipped` 和逐台 `status`。

小范围现场试运行可用[本地批量示例](examples/netdisco_backup.rb)，默认每厂商最多三台；`NET_CONNECTOR_SAMPLE_PER_VENDOR` 可设为 1 至 5。设备发起 TFTP 上传可用[批量 TFTP 示例](examples/netdisco_tftp_backup.rb)，默认每厂商最多五台；`NET_CONNECTOR_ALL=1` 才选择全部就绪设备，全量任务默认并发 50。`NET_CONNECTOR_CONCURRENCY` 可覆盖并发数。两类示例将结果和日志写入唯一的 `examples/backups/<UTC 时间戳>-<后缀>/` 目录，该目录不纳入 Git。

全量 TFTP 计划保存为 `plan.json`。目标文件名通常为 `<设备名>-<IP>.cfg`，Radware 用 `.tgz`，山石用 `.dat`。计划按实际文件名检查所有厂商的覆盖冲突，包括地址规范化后的重名；保留首个入选目标，其余标记为 `remote_filename_collision`。PAN-OS 固定使用 `running-config.xml`，还要求 `Sent ... bytes` 完成行。H3C 从 `display startup` 发现源文件，可用厂商环境变量覆盖；华为默认 `flash:/startup.cfg`。Nexus 9000 默认 VRF 为 `management`，山石为 `mgt-vr`；`NET_CONNECTOR_TFTP_VRFS` 接受按厂商键配置的 JSON，例如 `{"cisco_nxos":"backup","hillstone":"mgt-vr"}`。山石命令在 `vrouter` 参数后追加唯一的 `.dat` 文件名；直接调用山石连接器且不指定 `path:` 时，由设备生成文件名并在结果中返回。小批次会尝试回读服务器文件；全量任务跳过逐文件回读并标为未验证。可运行 `ruby examples/review_tftp_backup.rb <批次目录>`，根据会话日志复核剩余失败，而不改写原始结果。日志、`events.jsonl` 和逐台结果均以私有权限保存。

批量 TFTP 可用 `NET_CONNECTOR_<VENDOR>_TFTP_SOURCE_FILE` 指定单厂商源文件。`NET_CONNECTOR_H3C_TFTP_SOURCE_FILE` 与 `NET_CONNECTOR_H3C_WIRELESS_TFTP_SOURCE_FILE` 可分别覆盖 H3C 设备的自动发现结果；华为使用 `NET_CONNECTOR_HUAWEI_TFTP_SOURCE_FILE`。源文件是设备上的路径，需符合连接器校验规则。

本地配置备份写到 `<目录>/<IP>.txt`，IPv6 的 `:` 转成 `_`。设备改名不改变文件名或比较基线。若规范文件不存在，唯一匹配的旧版 `<设备名>-<IP>.txt` 可作比较基线但不会被改写；匹配多个旧文件时会明确失败。规范文件优先，符号链接和非普通文件会被拒绝。文件原子替换为 `0600`，新目录权限为 `0700`。批次在当前进程执行，需要定时任务或持久队列时由调用方安排；失败命令不会自动重试。

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `NETDISCO_URL` | 必填 | Netdisco 服务根地址，可包含租户路径 |
| `NET_CONNECTOR_CONFIG` | 未设置 | CLI 的非敏感 YAML 配置文件 |
| `NETDISCO_USERNAME`, `NETDISCO_PASSWORD` | 未提供 API 密钥时必填 | 清单 API 登录 |
| `NETDISCO_API_KEY` | 未设置 | 直接使用已有 API 密钥 |
| `NETDISCO_PAGE_SIZE` | `500` | 清单分页大小 |
| `NET_CONNECTOR_DEVICE_USERNAME`, `NET_CONNECTOR_DEVICE_PASSWORD` | 未设置 | 设备登录默认凭据 |
| `NET_CONNECTOR_<VENDOR>_USERNAME`, `NET_CONNECTOR_<VENDOR>_PASSWORD` | 未设置 | 单厂商凭据，例如 `CISCO_IOS` |
| `NET_CONNECTOR_BACKUP_DIRECTORY` | `./backups` | 备份及默认报告目录 |
| `NET_CONNECTOR_CONCURRENCY` | `4` | 并发设备数，范围 1 至 50 |
| `NET_CONNECTOR_INCLUDE_HOSTS`, `NET_CONNECTOR_EXCLUDE_HOSTS` | 未设置 | 逗号分隔的管理地址过滤器 |
| `NET_CONNECTOR_INCLUDE_VENDORS` | 未设置 | 逗号分隔的厂商标识过滤器 |
| `NET_CONNECTOR_VENDOR_OVERRIDES` | `{}` | Netdisco 厂商标签到连接器标识的 JSON 映射 |
| `NET_CONNECTOR_HOST_OVERRIDES` | `{}` | 管理地址到连接器标识的 JSON 映射 |
| `NET_CONNECTOR_DEVICE_RULES` | `[]` | 含 `vendor`、可选 `os` 或 `model_prefix` 及 `connector` 的映射规则 |
| `NET_CONNECTOR_PROTOCOL` | `ssh` | 默认连接协议，可按厂商覆盖 |
| `NET_CONNECTOR_KNOWN_HOSTS`, `NET_CONNECTOR_HOST_KEY_POLICY` | 系统主机记录、`strict` | SSH 主机密钥设置 |
| `NET_CONNECTOR_LOG_DIRECTORY` | 未设置 | 逐台会话日志目录 |
| `NET_CONNECTOR_LOG_LEVEL` | `info`（TFTP 示例为 `debug`） | `debug`、`info`、`warn`、`error` 日志级别 |
| `NET_CONNECTOR_TFTP_VRFS` | `{}` | NX-OS 和山石的 TFTP VRF 映射 |
| `NET_CONNECTOR_<VENDOR>_TFTP_SOURCE_FILE` | 按厂商决定 | 批量 TFTP 使用的设备源文件，H3C 可覆盖自动发现结果 |

设备映射规则先于厂商标签覆盖和内置规则执行，可用 `model_prefix` 区分同厂商型号：

```sh
export NET_CONNECTOR_DEVICE_RULES='[{"vendor":"Cisco","model_prefix":"N9K","connector":"cisco_nxos"}]'
```

`Settings` 创建客户端或规则时读取环境变量；每台任务启动时才读取设备凭据，因此新批次可接收轮换后的凭据。也可给 `Fleet.new` 注入 `credentials:` 解析器。`fleet.devices` 可在不连接设备时检查映射，随后用 `device.connector(...)` 创建连接器。

## 开发与验证

```sh
bundle install
script/ci
```

CI 在 Linux 和 macOS 上覆盖 Ruby 3.2、3.3、3.4、4.0。`script/ci` 扫描源码与可用 Git 历史中的敏感数据，执行 Ruby 与工作流 lint、完整测试，并验证已构建 gem 的隔离安装和本地 PTY 烟测；不连接真实网络设备。首次运行需下载固定校验和的 Gitleaks 与 actionlint。

`bundle exec rake test` 报告已加载库文件的行、分支覆盖率和未加载文件数；当前只记录基线，不作为发布门槛。`bundle exec rake lint` 检查 Ruby 代码，`bundle exec rake security:check` 扫描敏感数据，`bundle exec rake release:check` 执行完整预检。构建产物和脱敏扫描报告保存在被忽略的 `tmp/` 下。实现注释、公开文档和贡献模板均使用中文。

真实凭据应放在环境变量和版本库外的本地配置中。检查范围、依赖政策和忽略规则见[验证文档](docs/VERIFICATION.md)，发布流程见[发布文档](docs/RELEASING.md)。
