# Netdisco 与批量备份

[English](netdisco.md) | [返回首页](../README.zh-CN.md) | [设备操作](usage.zh-CN.md)

## Netdisco 清单与批量备份

`Net::Connector::Netdisco` 读取并验证完整清单，再将支持的记录映射到连接器，使用有上限的工作线程执行备份。Netdisco 只提供清单字段；设备凭据来自环境变量或调用方提供的解析器。清单会在连接任何设备前完成校验；不支持、被过滤、重复、缺少凭据、失败，以及保存成功但关闭失败的结果分别保留。

每次 `Inventory::HTTP#devices` 默认限制单响应 16 MiB、累计响应 128 MiB、去重前 100,000 条记录、10,000 页和 300 秒总期限。认证、分页及兼容查询共用这些预算；默认 HTTP 客户端逐块计数，超限会关闭连接并抛出带稳定 `code` 的 `Inventory::Error`，Fleet 不会执行半份清单。这些默认值是可调整的设计起点，不是实测容量。可注入 `requester: ->(uri, request)`；该回调只能在回调返回后检查正文和期限，回调自身的阻塞及内存用量由注入方控制。

推荐使用 HTTPS，标准证书验证保持开启。`allow_insecure_http` 默认为 `true`；设为 `false` 可在发请求前拒绝 HTTP，YAML 中对应 `netdisco.allow_insecure_http: false`。HTTP 会明文传输登录凭据和 API key，迁移时应先提供可验证的 HTTPS 端点。

`Fleet#plan_backup` 和 `Fleet#plan_tftp_backup` 从同一份清单生成计划。把计划传给 `backup_all(plan:)` 或 `tftp_backup_all(plan:)`，可使预览与执行选择同一批设备；计划与清单不符时会拒绝执行。单台设备异常或结果回调失败不会阻止其他设备。`batch.summary` 包含总数、成功、失败、部分成功、跳过、具体状态和逐台结果。部分成功包括已保存但关闭失败，以及本地文件已替换但目录同步或收尾失败；后者保留 backup 并标为 `saved_with_error`。TFTP 的 `reported_uploaded` 仅代表设备报告上传，不代表服务器文件已核验。

本地 `backup(path:)` 用 SHA-256 比较新旧配置，`backup.change` 返回 `:created`、`:changed` 或 `:unchanged`；内容未变且权限、文件身份正常时保留修改时间。这不补验历史写入的断电持久性。`backup_all` 的 `on_change:` 仅在新建或更改文件保存后触发；`on_start:` 和 `on_result:` 观察每台已尝试设备。回调异常记录在 `batch.callback_errors`，不丢弃设备结果。每项结果包含开始、结束和耗时。TFTP 无法比较服务器文件，因此没有 `change`，也不触发变更通知。

每批默认由 `Report::Store::Json` 写入私有 JSON 报告，路径见 `batch.report_location`。调用方如有数据库仓储，可传 `Report::Store::Database.new(repository: YourModel)`；仓储需实现 `create!(attributes)`。`report_store: nil` 表示由调用方自行持久化。报告失败保留在 `batch.report_error`，同时使 `batch.success?` 为假。若报告已替换但目录同步失败，仍保留位置；离线 `--export --output` 遇到同类错误返回 2，并说明文件已经提交。

Fleet 统一返回 `Netdisco::Report`，JSON 的 `schema_version` 固定为 `2`。报告包含 `policy`、`policy_success`、清单覆盖和受控诊断；`success?` / `status` 表示严格完成情况，`policy_success?` 表示所选成功策略。任务耗时使用单调时钟，UTC 开始/结束时间独立保留。`report.batch` 是原始执行快照；手工构造的 Batch 可用 `batch.build_report(policy: :selected)` 生成报告，不会再次执行设备或重写文件。

`success_policy: :selected` 要求至少一台设备成功，其他记录只因 `filtered` 或 `sample_limit` 跳过，而且没有部分成功、回调或报告错误。缺少凭据、重复地址、无效地址、未知厂商、目标冲突和未知状态均会阻止成功。`coverage.complete` 只表示每条清单记录都已尝试任务；失败任务也计入尝试，不能据此判断配置已保存。自定义 `Report::Store#write(report, directory:)` 始终接收 Report，并通过 `summary` 获取统一 JSON 结构。

外部构造的计划也必须把同一管理地址的全部条目标记为 `duplicate_host` 并跳过，不能通过采样恢复其中一条的执行资格；IPv6 的等价写法视为同一地址。只需汇总时使用 `report.statistics`，它返回 `summary` 除 `devices` 外的字段，不生成设备明细，也不缓存调用方持有的批次容器。

```sh
export ND_URL=https://netdisco.example/netdisco
export ND_USERNAME=inventory-reader
export ND_PASSWORD='replace-me'
export NC_DEVICE_USERNAME=backup-user
export NC_DEVICE_PASSWORD='replace-me'
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

命令行程序 `net-backup` 的 YAML 文件只允许非敏感设置；Netdisco 和设备凭据留在环境变量中。`ND_URL` 从环境覆盖 YAML 地址，`NC_PARALLEL` 覆盖 YAML 并发数；其他非敏感策略通过 YAML 或 CLI 设置。批量示例也支持 `NC_CONFIG`，可从 [完整配置示例](../examples/backup.yml) 开始。只有传入 `--config FILE` 或设置 `NC_CONFIG` 时才加载文件：

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
  parallel: 4
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

设置 `netdisco.source: postgres` 可以直接从数据库查询清单，继续使用同一套 Fleet、规则、计划和备份流程。库不内置表名、SQL 或业务筛选条件；必须提供查询，可直接修改 [YAML 示例](../examples/inventory.yml)：

```yaml
netdisco:
  source: postgres
  db_port: 5432
  db_sslmode: verify-full
  db_sslrootcert: /etc/net-connector/database-ca.crt
  db_connect_timeout: 10
  query: |
    SELECT host(ip) AS ip, name, dns, vendor, os, model, os_ver, serial
    FROM device
    WHERE vendor = $1
    ORDER BY ip
  query_params: [H3C]
```

查询必须返回唯一命名的 `ip` 列；可选列为 `name`、`dns`、`vendor`、`os`、`model`、`os_ver`、`serial`，其他列会丢弃。自定义表、视图、JOIN 和只读 CTE 均可用列别名适配这一契约。PostgreSQL 的 `inet` 字段建议用 `host(ip) AS ip` 去除前缀长度；筛选及排序由 SQL 决定。参数按数组顺序绑定 `$1`、`$2`，支持字符串、数字、布尔和 null，不做字符串插值或环境变量展开。

数据库身份只从 `ND_DB_HOST`、`ND_DB_NAME`、`ND_DB_USER`、`ND_DB_PASS` 读取，四项必填；HTTP 地址、API key 和设备登录凭据不是清单查询的前置条件：

```sh
export ND_DB_HOST=database.example
export ND_DB_NAME=netdisco
export ND_DB_USER=inventory-reader
export ND_DB_PASS='replace-me'

net-backup --config examples/inventory.yml --show-config
net-backup --config examples/inventory.yml --plan
# 覆盖查询参数；实际备份仍需设置 NC_DEVICE_* 凭据。
net-backup --config examples/inventory.yml --plan --query-params '["Cisco"]'
```

SQL、参数和来源也可分别通过 `--query SQL`、`--query-params JSON`、`--source postgres` 覆盖 YAML，不再从环境变量读取。SQL 和参数属于可公开配置，会出现在 `--show-config` 中；数据库密码只放在连接环境变量中。身份凭据不进入策略快照、计划、报告或 `inspect`；端口、TLS 和超时属于公开策略，进入快照与配置摘要。已有 Fleet 每次重新查询时读取最新连接凭据；传入已有 `plan:` 执行时不会重新查询。

客户端通过 `pg` 驱动执行只读事务，使用参数化游标分批取数，并在每批启用单行读取。PostgreSQL 原生解析拒绝多条语句，写入和锁定查询会失败；查询账户应仅授予所需表/视图的 SELECT 权限，只读事务不能替代账户权限隔离。驱动只在实际查询时加载，HTTP 和离线导出路径不加载它。

数据库查询复用现有清单预算：`page_size` 控制每次 FETCH 的行数，`max_pages` 限制 FETCH 次数，`max_devices` 在去重前计数；字节预算统计返回列名与文本值，包含最终丢弃的列。字节检查发生在 libpq 解码一行之后，不能限制单个超大字段在驱动内部的瞬时内存。连接、查询和全部 FETCH 共用总期限，同时设置数据库 statement_timeout。任一查询错误、超时或超限均关闭连接并丢弃整份清单，不连接设备；错误消息不输出原始 SQL、参数或数据库响应。建议只选所需字段，并提供明确的 ORDER BY 保持采样顺序稳定。

### 计划与执行

`--plan` 只拉取并验证清单；`--host` 选择一个管理地址；`--tftp` 默认每厂商最多选择五台，`--all` 选择所有就绪设备。本地备份默认选择所有就绪设备，可用 `--limit-per-vendor` 限制。`--show-config` 只输出有效的非敏感设置，不访问 Netdisco。CLI 会拒绝未知 YAML 字段、Ruby 对象标签及配置中的凭据。`--export IP` 只离线读取规范化管理地址对应的 `<IP>.txt`；默认原样写到标准输出，指定 `--output` 后以 `0600` 权限原子写文件。导出的配置仍是敏感数据。

这里的 `vendor` 表示连接器平台标识，如 `cisco_ios`、`cisco_nxos`，并非制造商；筛选和采样均按该标识分组。因此限制五台时，IOS 与 NX-OS 可各选五台。`source_vendor` 保留清单中的原始厂商标签。

CLI 的计划与批次摘要使用 JSON。默认 `--success-policy strict` 使用严格规则：非空清单且全部成功、回调及报告正常时为 `0`；空清单或有跳过、部分成功、失败时为 `1`；清单或配置错误为 `2`。`--host` 未在清单中找到也返回 `2`。由于其他清单记录会标记为过滤，默认单主机备份成功时批次退出码仍可能是 `1`；应查看 JSON 中的 `succeeded`、`skipped` 和逐台 `status`。

显式使用 `--success-policy selected` 后，CLI 按上述 selected 规则决定退出码，保留严格的 `status: incomplete` 与跳过计数，另列 `policy_success`。例如 `net-backup --config config.yml --host 192.0.2.7 --success-policy selected`。成功策略由本次 CLI/API 参数指定，不改变已批准的清单选择，也不触发重试。

本地批量示例和 TFTP 批量示例默认全量；显式 `--sample N` 或 YAML `backup.limit_per_vendor` 才限制每厂商数量（示例允许 1 至 5）。优先级为 CLI > YAML。并发默认 4，可用 `--parallel N`、环境变量 `NC_PARALLEL` 或 YAML `backup.parallel` 覆盖，优先级依次降低。两类示例在备份目录下创建唯一批次目录。TFTP 批量示例在可访问服务器目录时使用 hostname-ip 远端文件名并逐批归档；无法访问服务器目录时使用带批次标识的远端文件名，避免覆盖旧文件；上传完成与服务器文件验证是不同状态。

全量 TFTP 计划保存为 `plan.json`。目标文件名通常为 `<设备名>-<IP>.cfg`，Radware 用 `.tgz`，山石用 `.dat`。可访问本机 TFTP 服务器目录时，批量示例直接使用 `<设备名>-<IP>.<扩展名>` 上传，并在服务器的 `archive/<批次>/` 与本地 `<批次目录>/tftp/` 各保留一份；上传前已有的同名文件先保存到新归档目录的 `previous/`。无法访问服务器目录时，远端文件名增加东八区批次标识及同秒序号，避免覆盖旧文件；实际文件名见 `summary.json` 的 `remote_path`。计划仍检查同批目标名冲突。PAN-OS 固定使用 `running-config.xml`，还要求 `Sent ... bytes` 完成行；为避免下次上传覆盖它，运行批量示例时必须能访问本机 TFTP 服务器目录，否则该设备会明确失败且不会发起上传。H3C 从 `display startup` 发现源文件，可用 YAML `tftp.h3c_source_file` 覆盖；华为默认 `flash:/startup.cfg`。Nexus 9000 默认 VRF 为 `management`，山石为 `mgt-vr`；YAML `tftp.vrfs` 接受按厂商键配置的映射。山石命令在 `vrouter` 参数后追加唯一的 `.dat` 文件名；直接调用山石连接器且不指定 `path:` 时，由设备生成文件名并在结果中返回。通过 `--tftp-root DIR` 或 YAML `tftp.verification_root` 指定本机或已挂载的服务器目录时，批量示例在每台设备完成后核验实际回执路径、非空文件、修改时间和 SHA-256，并立即保存两份历史文件；报告的 `local_file` 和 `server_archive_file` 分别指向本地批次副本和服务器归档副本。核验或归档失败不会报告成功。未提供本机目录时，可命名设备仍使用不覆盖旧文件的远端文件名，回执保留为 `device_reported`，本地批次不包含配置副本。默认示例使用 `selected` 策略；要求服务器文件核验时使用 `--success-policy verified`，并提供本机服务器目录。日志、`events.jsonl` 和逐台结果均以私有权限保存。

批量 TFTP 源文件通过 YAML `tftp.h3c_source_file`、`tftp.h3c_wireless_source_file`、`tftp.huawei_source_file` 设置。源文件是设备上的路径，需符合连接器校验规则。

本地配置备份写到 `<目录>/<IP>.txt`，IPv6 的 `:` 转成 `_`。设备改名不改变文件名或比较基线；只读取该规范路径，缺失时创建新备份。其他名称的文件不参与查找或哈希比较。Fleet 和离线读取拒绝符号链接及非普通文件。文件原子替换为 `0600`，新目录权限为 `0700`。批次在当前进程执行，需要定时任务或持久队列时由调用方安排；失败命令不会自动重试。

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `ND_URL` | HTTP 模式必填 | Netdisco 服务根地址，可包含租户路径 |
| `NC_PARALLEL` | 默认 4，范围 1 至 500 | 备份、配置批次和接口修正共用的并发数 |
| `ND_CACHE_TTL` | 默认 259200 秒（三天） | 清单缓存有效期，须为有限正数，优先于 YAML `netdisco.cache_ttl` |
| `NC_CONFIG` | 未设置 | CLI / 批量示例的非敏感 YAML 配置文件 |
| `ND_USERNAME`, `ND_PASSWORD` | 未提供 API 密钥时必填 | 清单 API 登录 |
| `ND_API_KEY` | 未设置 | 直接使用已有 API 密钥 |
| `ND_DB_HOST`, `ND_DB_NAME` | PostgreSQL 模式必填 | 数据库主机或 Unix socket 目录、数据库名 |
| `ND_DB_USER`, `ND_DB_PASS` | PostgreSQL 模式必填 | 仅从环境注入的数据库用户名、密码 |
| `NC_DEVICE_USERNAME`, `NC_DEVICE_PASSWORD` | 未设置 | 设备登录默认凭据 |
| `NC_<VENDOR>_USERNAME`, `NC_<VENDOR>_PASSWORD` | 未设置 | 单厂商凭据，例如 `CISCO_IOS` |
| `NC_ENABLE_PASSWORD`, `NC_<VENDOR>_ENABLE_PASSWORD` | 未设置 | 可选提权密码 |

Netdisco 环境变量使用 `ND_`，连接器使用 `NC_`，仅支持上表列出的变量，不保留旧名别名。凭据保持在环境变量中，YAML 不接受密码。端口、TLS、CA 文件、连接超时使用 YAML `netdisco.db_port`、`db_sslmode`、`db_sslrootcert`、`db_connect_timeout`；TFTP 使用 `tftp.server`、`tftp.verification_root`；进度由 `--no-progress` 控制。其他策略也使用 YAML 或 CLI，旧变量和已移除的设置会明确报错，不输出变量值。

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

每台任务开始时仍读取设备凭据，`Settings.from_file` 也保留轮换能力。纯策略快照不保存密码、API key 或凭据解析器。需要让多次 API 调用共用策略时，可传 `Settings.new.for_run(mode: :backup)`。自定义 `credentials:` 解析器仍可逐设备返回连接设置，它显式给出的选项优先于批次默认值，由调用方负责一致性；注入的 `inventory:` 生命周期也由调用方管理。传入 `plan:` 的执行不会重新拉取或筛选已批准清单。`fleet.devices` 可在不连接设备时检查映射。

快照中的备份、缓存、日志、本地 TFTP 核验目录、SSH known-hosts 路径及显式 PostgreSQL CA 证书路径，以创建快照时的工作目录为基准，默认路径和后续相对路径覆盖也沿用这一基准。`~/` 开头的路径及 `~` 使用快照创建时的主目录。TFTP 的 `ssh://user@host/绝对目录` 核验 URI 保留原值，不作本地路径展开，且必须启用历史归档；SSH 认证、远端要求和并发限制见[示例设置](../examples/README.md#ssh-服务器核验与归档)。PostgreSQL CA 路径保留 libpq 的字面路径语义，不展开波浪号；`sslrootcert: system` 仍表示系统信任库，`./system` 则表示文件。未固定的活设置仍按调用时的当前工作目录和主目录解析路径。

地址和厂商覆盖规则规范化后，同一键不能指向不同连接器；指向同一连接器的别名可以并存。必需的厂商标签规范化后也不能为空。非法规则在连接设备前拒绝。

## 批量示例与进度

批次连接设备前会为 SSH 管道、设备伪终端、日志及文件锁预留文件描述符额度；需要时只在本进程硬上限内提高软额度，不修改终端和系统配置。硬上限不足时先停止整批，并提示调整 `ulimit -n` 或降低 `--parallel`。SSH 归档连接按各服务器实际设备数分配，连接预检最多四条同时进行。

`examples/backup.rb` 和 `examples/backup_tftp.rb` 默认全量备份符合筛选条件的设备，并在终端原地刷新两行进度（登录、采集、排队、成功和未完成数，以及耗时、平均吞吐、预计剩余时间）；失败单独输出，结束后显示汇总和报告路径。重定向时每 25 台输出一次进度，避免刷屏。`--verbose` 显示逐条登录和命令事件，`--json` 才在 STDOUT 输出 JSON；完整计划和结果始终保存在批次目录。`--no-progress` 关闭人类进度。百分比表示任务完成比例，不是成功率。

```sh
ruby examples/backup.rb             # 全量，默认并发 4
ruby examples/backup.rb --sample 3  # 每厂商最多 3 台
ruby examples/backup.rb --verbose  # 详细命令过程
ruby examples/backup.rb --json > result.jsonl
ruby examples/backup.rb --parallel 10 --username backup-user --ask-password
```

批量示例支持 `--parallel`（1 至 500）、`--username`、`--password`、`--enable-password`、`--netdisco-url`、`--netdisco-username`、`--netdisco-password`、`--directory` 和 `--config`。命令行优先于环境变量与 YAML；显式设备凭据逐字段覆盖对应厂商凭据。指定 Netdisco 用户名或密码时不再沿用环境中的 API key。密码可使用 `--ask-password` / `--ask-netdisco-password` 隐藏输入，避免命令行密码进入 shell 历史或进程参数；自动化仍可用环境变量或原有 `--stdin-credentials`。`--config` 与 `--directory` 的相对路径基于项目根目录。

## 部署、示例与验证

```sh
bundle install
script/ci
```

CI 在 Linux 和 macOS 上覆盖 Ruby 3.2、3.3、3.4、4.0。`script/ci` 扫描源码与可用 Git 历史中的敏感数据，执行 Ruby 与工作流 lint、完整测试，并验证已构建 gem 的隔离安装和本地 PTY 烟测；不连接真实网络设备。首次运行需下载固定校验和的 Gitleaks 与 actionlint。

`bundle exec rake test` 报告当前测试进程的行、分支覆盖率和未加载文件清单。核心引擎、脱敏与错误处理（含 `Redactor`）、批量工作线程分别要求行和分支覆盖率均达到 80%，关键文件没有覆盖率数据也会失败；该门槛同时阻止 CI 和发布预检通过。`bundle exec rake lint` 检查 Ruby 代码，并对 `engine/`、`netdisco/` 限制方法长度（40）和 ABC 复杂度（60）。`bundle exec rake security:check` 扫描敏感数据，`bundle exec rake release:check` 执行完整预检。构建产物和脱敏扫描报告保存在被忽略的 `tmp/` 下。

参与开发见 [CONTRIBUTING.md](../CONTRIBUTING.md)，漏洞报告见 [SECURITY.md](../SECURITY.md)。README 和使用指南提供英文、中文版本；实现注释与架构参考使用中文，欢迎中文或英文的问题与 PR。

真实凭据应放在环境变量和版本库外的本地配置中。检查范围、依赖政策和忽略规则见[验证文档](VERIFICATION.md)，发布流程见[发布文档](RELEASING.md)。

备份示例通过 `examples/boot.rb` 读取项目根目录 `.env`，不会自动切换依赖或注入源码路径。直接 `ruby examples/backup.rb`（或在 `examples/` 中执行 `ruby backup.rb`）使用已安装的 gem；修改库后必须重新构建并安装，开发源码验证则使用 `bundle exec ruby examples/backup.rb`。示例中的相对备份、日志路径统一基于项目根目录；进程中显式传入的 `NC_CONFIG` 路径按启动目录解析。

清单自动识别保留显式主机映射、设备规则和厂商覆盖的优先级。若厂商标签陈旧，而 `os: Comware` 与 `model: H3C ...` 同时确认 H3C，则自动使用 H3C 连接器；`H3C WX...` / `H3C AC...` 使用无线连接器。仅型号片段或操作系统单项不会覆盖其他厂商。

备份部署示例 `examples/backup.yml` 使用 `ssh.host_key_policy: accept_new`：首次连接自动登记到 OpenSSH known_hosts，已有密钥变化仍拒绝连接。`--host-key-policy strict|accept_new` 可覆盖本次策略，`--known-hosts FILE` 指定持久保存位置；不应删除密钥文件，否则会丢失历史身份记录。库本身默认仍为 strict。

设备密钥变化也需自动更新时，使用 `--host-key-policy replace --known-hosts FILE`，或在 YAML 设置 `ssh.host_key_policy: replace` 与 `ssh.known_hosts`。文件必须显式指定；只在主机密钥变化错误时删除该设备旧记录并重连一次，不重放设备命令。建议使用备份任务专用的持久密钥文件。

进度每秒更新一次心跳；设备无新输出时仍显示耗时，超过 10 秒的最久任务显示地址、阶段与任务耗时。预计剩余时间按已完成任务的平均吞吐计算，前五台完成前显示“估算中”，异构设备和末尾慢任务会使估算波动。终端事件刷新最多约每秒五次，退出或异常时回收显示线程；结束按错误代码汇总未完成任务。

本地批量示例将配置写为 `hostname-ip.txt`（名称取 Netdisco name/dns），空名称使用 `unnamed`，特殊字符清理，IPv6 冒号替换为下划线。批次目录固定使用 UTC+8 的 `YYYY-MM-DD_HH-mm-ss`，同秒冲突追加 `_01` 等序号。每批包含 `plan.json`、`summary.json` 和人类可读的 `summary.txt`（时间、计数、失败分类及失败明细），报告权限为 0600。历史目录不改名；通用 Fleet/CLI 仍默认 IP 文件名，API 可显式传入 `filename_style: :hostname_ip`，该模式设备改名会改变文件路径与比较基线。

公共备份辅助接口随 gem 分发，不依赖 examples 文件：

```ruby
require "net/connector/netdisco"
netdisco = Net::Connector::Netdisco
options = netdisco::CLI::Options.parse(argv: ["--parallel", "10"])
settings = netdisco::CLI::Options.settings(options)
inventory, credentials = netdisco::CLI::Credentials.resolve(settings)
directory = Net::Connector::Storage::BatchDirectory.create("./backups")
# 获得 report 和 plan 后：
# report = netdisco::Report::Files.write(report, directory: directory, plan: plan, parallel: 10)
```

`CLI::Options.parse` 接受 `argv/input/output/error/program`，不修改传入参数数组；帮助通过返回值 `:help` 通知调用方，非法输入抛出 `ArgumentError`。`CLI::Credentials.resolve` 接受 `input:`，标准输入凭据仅消费一行，RUN 确认由脚本编排负责。模块不加载 `.env` 或切换目录。

批量示例由 `Netdisco::CLI::Backup` 统一编排，`CLI::Options.settings` 为示例和正式 CLI 共用配置覆盖入口。

终端入口按职责放在 `cli/`：`CLI::Backup` 编排批量备份，`CLI::Topology` 编排发现、规划与显式应用，`CLI::Credentials.resolve` 解析凭据来源，`CLI::Options` 解析参数和配置覆盖。示例显式传入 `load_env: true`，将公开环境变量作为 YAML 和 CLI 之下的默认值；正式 CLI 保留既有的环境覆盖规则。
示例默认 `selected`，正式 CLI 保留 `strict` 默认；两者均支持显式 `--success-policy`，退出码与报告的 `policy_success` 一致。
示例 `summary.json` 使用标准 schema 2 的 `devices`，逐台结果与诊断统一保存在批次报告中。
TFTP 的 `verification` 汇总与设备条目的 `server_file_verified` 区分上传回执和服务器文件核验，核验成功还包含 `local_file`、`server_archive_file`、`bytes`、`sha256`。
报告通过私有原子写入保存；报告保存失败会阻止成功退出，终端最终结果在报告保存之后输出。

`--stdin-credentials` 的一行 JSON 保留 `netdisco_username`、`netdisco_password`、`device_username`、`device_password` 四个字段。
清单来源为 PostgreSQL 时，前两个字段覆盖数据库用户名和密码，主机和数据库名仍由 `ND_DB_HOST`、`ND_DB_NAME` 提供，TLS 参数来自 YAML；第二行 `RUN` 仍是执行设备任务的确认。

使用 `accept_new` / `replace` 时，SSH 在每个会话的临时 known_hosts 中协商，认证后通过独立锁文件合并到共享文件。
网络登录不占用共享锁；失败登录不删除原信任记录，`replace` 只替换当前主机。该同步协调本库进程，外部手工工具应避免同时改写同一文件。
认证后的合并锁另有最多 `login_timeout` 秒的等待预算，超时返回 `ConnectionError`（`code: :known_hosts_busy`），关闭会话且保留共享信任记录；此预算只约束锁等待，不是整批任务的期限。

提供 `verification_root:` 时，即使不保留历史，TFTP 核验也在目标锁内采集上传前文件状态与文件系统时间、执行上传并检查指纹。未变化的旧文件不能凭未来时间戳获得服务器核验；服务器目录须可写以建立锁和时间探针。结果回调与最终报告采用核验后的结果，文件证据不覆盖设备操作或关闭故障。回执路径与锁定目标不一致时保留设备证据，但缺少该路径的上传前基线，不核验或归档旧文件。

本地备份或 TFTP 归档完成后若路径锁收尾失败，结果以 `:saved_with_error` 或 `:reported_with_error` 保留已保存路径。已有设备错误仍作为首个诊断，回调收到保留回执的结果，命令不自动重放。

## 清单缓存

HTTP 和 PostgreSQL 默认启用本地清单缓存，有效期三天（259200 秒），目录为当前工作目录下的 `.cache/net-connector/inventory`。YAML `netdisco.cache_directory`、`cache_ttl` 和 `cache_enabled` 分别控制目录、秒数和是否启用；TTL 须为有限正数，设置 `cache_enabled: false` 关闭缓存。

环境变量 `ND_CACHE_TTL=86400` 可将有效期改为一天。优先级为显式设置覆盖 > 环境变量 > YAML > 三天默认值；批次启动时固定有效期，修改环境不会改变正在执行的批次。

目录必须属于当前用户且权限为 `0700`，缓存和锁文件为 `0600`。不同来源、地址、账号、数据库和 SQL 参数隔离缓存，只保存白名单清单字段，不保存密码、API key、SQL 或额外响应字段。每次读取仍应用当前筛选和厂商规则，远端成功返回空数组时替换旧清单。

过期后自动刷新；远端请求失败时回退已验证历史，不更新原获取时间。配置错误、缺少凭据、中断和不安全文件不会被回退掩盖。缓存写入失败仍交付刚取得的新清单。`fleet.inventory_status` 提供 `:fresh_cache`、`:refreshed`、`:stale_cache`、`:uncached`、原始 `fetched_at` 和安全故障字段，CLI 对历史回退和缓存写入失败单独提示。

空文件或格式损坏的缓存按未命中处理，重新查询远端；查询失败时，这类文件不能作为回退历史。

强刷使用 `net-backup --refresh-inventory`、`fleet.devices(force_refresh: true)`、`fleet.plan_backup(force_refresh: true)`；TFTP 规划也支持此参数。强刷失败同样回退已验证历史。直接注入客户端时不自动缓存，可显式包裹 `Netdisco::Inventory::Cache`。一个包装器的状态描述最近调用，并发共享实例须由调用方同步。有界跨进程锁合并普通过期刷新，独立强刷请求各自访问远端。

## 配置批次与接口修正

```ruby
fleet = Net::Connector::Netdisco::Fleet.new
batch = fleet.execute_scripts(
  scripts: { "192.0.2.1" => ["system-view", "interface GigabitEthernet1/0/1", "description uplink", "quit", "quit"] },
  confirmed: true,
  parallel: 4
)
puts JSON.pretty_generate(batch.to_h)
puts "总数=#{batch.summary[:total]} 成功=#{batch.summary[:succeeded]} 失败=#{batch.summary[:failed]}"

batch = fleet.sync_interface_descriptions(hosts: ["192.0.2.1"])
puts "清单 #{batch.summary[:total]}，成功 #{batch.summary[:succeeded]}，失败 #{batch.summary[:failed]}"
```

脚本接受 `Script`、命令数组或多行文本。全批先解析并固定脚本、规范化地址，再读取凭据或连接设备；重复、未知、过滤和不支持的目标提前拒绝。脚本须包含对应厂商的完整命令，包括进入/退出配置视图及需要的保存命令。空批次为 `:no_devices`，不判为成功。

默认使用 `sync_interface_descriptions` 一次完成发现、修改、读回与保存，每台设备只建立一个连接，描述一致时不修改、不保存。默认格式为 `To_<邻居名称>_<接口简称>`，各厂商规则见[设备指南](usage.zh-CN.md#邻居发现与接口描述)；定制规则留给后端参数或代码块。无变化成功不证明先前已保存。需要单独预览审批时，后端仍可使用 `plan_interface_descriptions` 与 `apply_interface_descriptions(plans: planned.plans, confirmed: true)`。

接口应用复用单设备拓扑操作，保留证据重验、配置回读和持久化确认，不将审批计划当作普通脚本执行。脚本与独立计划应用要求 `confirmed: true`；显式同步调用本身表达修改意图，不自动重放命令。每台任务独占并关闭连接器；普通失败隔离为设备结果，中断停止并等待全部工作线程。跨设备已完成的变更不会自动回滚。

`Operations::Batch` 独立于备份报告，`outcomes` 保留原 `Result` 或计划、完成步骤和第一故障；`:partial` 表示已有工作后出错，缺少凭据也使批次不成功。`plans` 只选完整成功的规划结果。`to_h` 仅输出安全诊断和数量，不展开命令、回显、凭据或证据。`on_start` 和 `on_result` 在工作线程执行，回调须线程安全；普通回调故障记录后继续，不重复设备操作。日志使用 `ssh.log_directory`。

每台设备独占会话，在操作和关闭完成后发布一个不可变终态。连接、凭据、执行和关闭的普通故障只影响该设备，其他运行中或排队任务继续。整批调度结束后返回完整结果；`summary` 和 `to_h[:summary]` 提供 `total`、`succeeded`、`failed`，满足总数 = 成功 + 失败，并细分 `partial`、`missing_credentials` 和 `callback_errors`。总数是本次请求并调度的设备数量；部分完成与缺少凭据计入失败，回调故障单列，不改写设备执行结果。空批次各项为零且状态为 `no_devices`。库不直接输出终端内容，调用方可将 `to_h` 导出 JSON 报告。设备上的已完成变更不能回滚；全批审批预检和显式中断仍维持原有失败边界。

其他独立任务可加载 `net/connector/parallel/pool`，通过 `Net::Connector::Parallel::Pool.new(parallel: 4).map(items) { |item| ... }` 执行。结果按输入顺序返回，全部线程建立成功才运行块，未处理异常会停止线程池并回到调用线程。业务代码负责决定哪些普通错误转换为单任务结果。显式参数优先于 `NC_PARALLEL` 环境变量，默认 4、上限 500。

取消批次时退出码为 130，摘要状态为 `interrupted`。已完成设备保留文件与上传回执；未完成槽位分别标记 `interrupted` 和 `not_started`，不会自动重试。`events.jsonl` 的 `artifact` 保存已完成备份或上传的元数据，不包含配置正文。库调用者仍收到原始 `Interrupt`，可从同一 Fleet 的 `last_report` 读取部分结果；新的运行会清除旧报告。

并行入口现为 `net/connector/parallel/pool` 和 `Net::Connector::Parallel::Pool`。旧 `parallel` 加载路径及 `Parallel` 命名空间已移除。内置 TextFSM 模板移至 `lib/net/connector/textfsm/`；使用默认模板目录的调用无需修改，手工拼接旧资源路径的调用需更新。

拓扑描述比较保留语义一致的旧值。`topology.neighbor_name_prefixes: ["AP-"]` 可显式声明历史名称前缀，仅用于比较；默认空列表不猜测名称前缀。未知邻居身份不生成命令，其他已核实接口仍可独立规划。

拓扑示例按备份命名规则输出 `scripts/设备名-IP.cfg` 和 `devices/设备名-IP.txt`，计划与摘要记录路径及命令文件 SHA-256。无变更、发现及失败结果不生成空命令文件。导出失败阻止应用，文本导出不能绕过现场证据重验。

拓扑默认输出中文分类摘要，待核实证据和执行失败分别统计；`--verbose` 显示逐设备事件。JSON 状态码保持稳定并新增 `statistics`，存在待变更或未核实证据时退出码仍为 1。启动显示实际配置文件；`NC_CONFIG` 也优先于拓扑示例默认文件，共享配置须补充对应 `topology` 策略。
