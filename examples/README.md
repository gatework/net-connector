# 配置备份与拓扑示例

这些脚本使用本仓库的 `CLI::Backup`、`CLI::Topology` 与设备接口，支持 Ruby 3.4 或更新版本。先在项目根目录安装依赖，再通过项目 Bundler 运行：

```sh
bundle install
bundle exec ruby examples/backup.rb --help
bundle exec ruby examples/backup_tftp.rb --help-all
bundle exec ruby examples/topology.rb --examples
```

也可以在 `examples/` 中运行 `ruby backup.rb --help` 或 `bundle exec ruby backup.rb --help`。两种方式均加载入口相邻发行目录的 `lib/`，避免仓库入口混用另一份已安装的 net-connector。第三方依赖沿用调用方选择的 RubyGems/Bundler 环境，不自动切换 Gemfile 或搜索相邻工作树。正式 `net-backup` 命令使用所安装的 gem。

示例入口测试统一位于 `test/`，并纳入 `bundle exec rake test`。单独运行示例测试：

```sh
bundle exec ruby -Itest -e 'Dir["test/examples*_test.rb"].sort.each { |file| require_relative file }'
```

`boot.rb` 只加载相邻项目库，不读取配置或改变加载路径。三个入口和正式 `net-backup` 共用 `Net::Connector::Config`，不会修改进程 `ENV` 或工作目录。配置值按 **CLI > 原进程环境 > YAML > .env > 内置默认值** 覆盖；凭据只从环境及显式 CLI 读取，YAML 不接受密码。

配置目录按低到高为 `/etc/net-connector`、`/usr/local/etc/net-connector`、`$XDG_CONFIG_HOME/net-connector`（默认运行用户的 `~/.config/net-connector`）、入口脚本目录、启动目录；重复目录只读一次，不向父目录递归搜索。每层先加载 `net-connector.yml` 的 `common` 和当前工具命名空间，再加载 `backup.yml` 或 `topology.yml`。共享文件的 `common` 只包含 `netdisco`、`inventory`、`ssh`；`backup`、`topology` 命名空间包含完整的原生工具配置。显式 `--config FILE` 或 `NC_CONFIG` 文件最后叠加，保留低层未覆盖字段。

各目录的 `.env` 按同样顺序加载，`--env-file FILE` 最后叠加，进程环境始终优先。`.env` 中的 `NC_CONFIG` 相对该环境文件解析，原进程及 CLI 路径相对启动目录；YAML 的本地缓存、known_hosts、日志、输出及 TFTP 路径相对各自文件解析，SSH TFTP URI 原样保留。数组整体替换。显式文件不存在或格式错误时停止，自动候选不存在则跳过。单个 YAML 文件禁止重复键和多个文档，避免静默丢弃配置。`--show-config` 显示公开设置与来源路径，不输出密码或 `.env` 正文。帮助不读取配置文件。

旧入口曾切换到项目根目录；迁移现有配置时应按来源文件调整相对路径。例如 `examples/.env` 使用 `NC_CONFIG=backup.yml`，`examples/backup.yml` 使用 `backup.directory: backups`；若继续复用项目根目录的缓存，则使用 `netdisco.cache_directory: ../.cache/net-connector/inventory`。旧并发变量 `NC_CONCURRENCY` 改为 `NC_PARALLEL`。可用 `ruby backup.rb --show-config` 核对实际路径和覆盖来源，不连接设备。

## 入口与配置

| 文件 | 用途 |
| --- | --- |
| `backup.rb` / `backup.yml` | 全量运行配置采集与本地备份 |
| `backup_tftp.rb` / `backup.yml` | 批量原生 TFTP 导出及可选服务器核验/归档 |
| `topology.rb` / `topology.yml` | 邻居发现、描述审计、只读规划和显式应用 |
| `inventory.yml` | PostgreSQL 查询、缓存、筛选及备份策略 |

`backup.example.yml` 是公开参考模板；现场 `backup.yml` 不进入 Git。备份输出默认是启动目录的 `backups/`，拓扑报告默认是启动目录的 `topologys/`。输出目录也可由 YAML、进程环境或 `--directory` 设置。原进程的共享 `NC_PARALLEL` 也覆盖 YAML 的 `topology.parallel`；同层同时设置时，专用 `NC_TOPOLOGY_PARALLEL` 优先，CLI `--parallel` 最高。

`--init` 在用户配置目录创建缺失的工具 YAML 和 `.env`，或使用显式 `--config` / `--env-file` 路径；不写入 gem 安装目录。`--interactive` 可通过终端确认创建并逐项填写。已有文件不覆盖，新文件权限为 `0600`，创建后立即退出，不读取清单或连接设备。每个文件独立原子发布，取消不会留下半份文件。

自动化中默认不问答、不消费标准输入，也不自动创建文件；需要初始化时显式执行：

```sh
ruby examples/backup.rb --init --non-interactive -p 8
ruby examples/backup_tftp.rb --init --non-interactive
ruby examples/topology.rb --init --non-interactive
```

`--init` 只创建缺失文件并退出；`--interactive` 要求终端，`--non-interactive` 禁用问答。`--help`、`--help-all`、`--examples` 均不读取清单、不创建文件。初始化 YAML 会保留已识别的公共环境变量和本次参数，默认并发 4（支持 1～500）、SSH 接受首次主机密钥但拒绝已变更密钥、清单缓存 3 天、清单读取预算 300 秒、拓扑只读 `plan`。密码不复制到生成文件，环境模板仅列出待填写的凭据变量；含 `#` 或 `$` 的密码使用单引号包裹。

生成后填写 `netdisco.url` 或 `ND_URL`，并设置实际清单和设备凭据。TFTP 需配置真实 `tftp.server` 或 `tftp.servers`，以及实际文件核验/归档目录；不生成假服务器、VRF、源接口或固定启动文件名。配置初始化不代表认证或备份验证通过。

以下命令从项目根目录运行：

```sh
bundle exec ruby examples/backup.rb --help
bundle exec ruby examples/backup.rb --examples
bundle exec ruby examples/backup.rb --plan --host 192.0.2.10
bundle exec ruby examples/backup.rb --inventory-only --name edge --cache-only
bundle exec ruby examples/backup.rb --hosts 192.0.2.0/24 --exclude-name wlc --parallel 8
bundle exec ruby examples/backup.rb --sample 3 --verbose
bundle exec ruby examples/backup.rb --config examples/inventory.yml --plan
```

## 清单、凭据与缓存

只选择 Netdisco 清单已有设备，不展开网段或扫描地址。地址支持精确 IP、CIDR、完整范围和 IPv4 末段简写 `192.0.2.10-20`，IPv6 范围使用完整端点。地址、名称和厂商条件取交集，排除优先。名称忽略大小写，支持 `contains`、`prefix`、`glob`；多个同类 CLI 参数取并集，覆盖同类 YAML 策略。`--host` 与 `--hosts` 互斥。

```sh
bundle exec ruby examples/backup.rb --plan --hosts 192.0.2.10-20 --name edge --exclude-name core,wlc
bundle exec ruby examples/topology.rb --inventory-only --name-match glob --name 'edge-*' --vendor h3c --cache-only
```

凭据仍来自环境、显式 CLI 或调用方注入，不写入 YAML。单设备 TFTP 使用 `backup_tftp.rb --host IP`，与批量执行共用凭据、连接策略、核验和报告。HTTP 使用 `ND_URL`、`ND_USERNAME` / `ND_PASSWORD` 或 `ND_API_KEY`；PostgreSQL 使用 `ND_DB_HOST`、`ND_DB_NAME`、`ND_DB_USER`、`ND_DB_PASS`。设备使用 `NC_DEVICE_USERNAME`、`NC_DEVICE_PASSWORD`，可选 `NC_ENABLE_PASSWORD` 及按厂商凭据覆盖。PostgreSQL 使用项目已声明的 `pg` 驱动；示例 `.env` 不进入版本库。环境模板见 `.env.example`。公开设置如 `NC_BACKUP_DIRECTORY`、`NC_HOST_KEY_POLICY`、`NC_KNOWN_HOSTS`、`NC_TFTP_HOST`、`NC_TFTP_ROOT` 由 CLI 按统一优先级解析：进程环境覆盖 YAML，YAML 覆盖 `.env`；结构化映射使用 JSON，列表使用逗号分隔；YAML 声明列表或映射字段时整体覆盖该字段。旧 `NETDISCO_URL/USERNAME/PASSWORD` 应改为 `ND_URL/USERNAME/PASSWORD`，`TFTP_ROOT` 应改为 `NC_TFTP_ROOT`，不改变赋值内容。

| 缓存模式 | 行为 |
| --- | --- |
| `prefer` | 有效缓存优先；过期刷新失败时回退已验证历史 |
| `only` / `--cache-only` | 只读身份匹配的已验证缓存，允许过期，不触网或写锁；无有效缓存即失败 |
| `refresh` / `--refresh-inventory` | 强制刷新，失败仍可回退已验证历史 |

备份配置使用 `netdisco.cache_mode`，拓扑使用 `topology.cache_mode`，CLI `--cache-mode` 可覆盖。离线仍需相同的端点、用户名/身份及查询策略，密码可以省略；缓存 only 与强刷互斥。`--inventory-only` 不请求设备凭据或创建批次目录，TFTP 清单预览也不要求服务器配置。

## 默认及设备级 TFTP

`backup.yml` 展示全局服务器、设备服务器覆盖、厂商默认及逐设备源接口/源文件/VRF。地址均为文档保留地址，运行前替换为实际设备和可达服务器。`default` 提供厂商默认，`hosts` 用精确设备 IP 覆盖；可选字段的显式 `null` 清除覆盖并使用设备协议缺省，空字符串非法。

- H3C/H3C 无线：`management` 使用设备连接 IPv4 作为本次传输源；可设置 `Vlan-interface10` 等明确接口。
- Radware：`management` / `data` 对应本次传输的 `-mgmt` / `-data`。
- Nexus/山石：`vrfs` 支持厂商默认和设备覆盖；`source_files` 适用于 H3C/H3C 无线/华为。

服务器核验目录通过 `verification_roots` 按服务器绑定；设备切换服务器不会沿用原服务器目录，不同服务器不能共用同一核验目录。启用本机核验时，给每台选中设备对应的服务器设置实际可写目录。`--plan` / `--inventory-only` 只预览清单；执行批次的 `plan.json` 保存有效传输策略，执行拒绝已绑定策略漂移。不支持的显式选项在连接前报错。

```sh
bundle exec ruby examples/backup_tftp.rb --plan --hosts 192.0.2.10-20 --json --quiet
bundle exec ruby examples/backup_tftp.rb --tftp-root /srv/tftp --success-policy verified
```

有本机或挂载根目录时，以 hostname-IP 文件名上传，核验实际回执路径、非空文件、文件变化及 SHA-256，分别保存服务器 `archive/<批次>/` 和本地 `<批次>/tftp/` 副本；同名旧文件先存入 `previous/`。两份归档核验成功后清理服务器暂存文件，历史副本继续保留。无本机目录时，普通设备使用带批次后缀的远端名，保留 `device_reported`，不冒充已核验或已有本地配置副本。PAN-OS 固定 `running-config.xml`，需要本机根目录才能安全保留历史，否则不上传。`verified` 要求全部选中设备具有匹配的服务器目录并通过核验。

## SSH 服务器核验与归档

当 TFTP 目录只在远端服务器时，`tftp.verification_roots` 可按服务器绑定无密码 URI：

```yaml
tftp:
  server: 192.0.2.10
  verification_roots:
    "192.0.2.10": ssh://archive@192.0.2.10/srv/tftp
```

远端需要 Python 3、POSIX 文件锁及该目录的读写权限，客户端使用本机 OpenSSH。
主机密钥须已受信任。密码认证在发现的 `.env` 或进程环境中配置 `NC_TFTP_SSH_PASSWORD`；
未配置时只尝试可用的 SSH 密钥/agent。脚本从不弹出服务器密码提示。
没有可用凭据时退出码为 2，明确提示凭据配置方式，且不连接设备。
密码通过不记录日志的私有终端交互发送，不进入 YAML、SSH 命令参数、计划或报告。
服务器连接失败时在设备任务开始前停止，本次批次不会逐台重试服务器认证。

归档在同一服务器锁内保存旧文件、执行设备上传、核验变化和 SHA-256，再保留服务器与本地两份副本；
两份核验后才清理暂存文件。PAN-OS 固定文件名串行处理，归档失败保留回执与已保存的路径，不重传。
SSH 归档最多并行 4 台，单文件上限 64 MiB；服务器归档路径在报告中以 `ssh://` URI 表示。
`--success-policy verified` 可要求本批设备全部通过服务器文件核验。

## 拓扑发现与应用

拓扑与备份入口共用 `--help` 常用帮助、`--help-all` 完整参数和 `--examples` 范例；支持相同的配置初始化、名称/IP/厂商筛选、缓存控制、`--parallel 1..500`、进度和 `--json` 输出。`--directory` 指定拓扑报告目录。`--inventory-only` 只预览清单，`--limit N` 限制本次可发现设备数。

拓扑默认只打印批次进度、中文设备/接口统计和报告位置；未知邻居名称属于待核实项，连接或命令失败单独计数。`--verbose` 才显示逐设备详情。JSON 保留原状态码，新增 `statistics`；有变更或未核实证据仍返回退出码 1。启动时显示实际配置路径；`NC_CONFIG`（包括 `.env` 中的值）作为最后一层配置，共享 `backup.yml` 时须将拓扑策略放入其 `topology` 段。

每个批次按设备输出 `scripts/设备名-IP.cfg`（一行一条设备 CLI 命令）和 `devices/设备名-IP.txt`（状态、描述比较与未核实项）。文件名沿用配置备份的设备名/IP 清理规则，同名不同 IP 不冲突。只有已核实且有变更的设备生成 `.cfg`，无变更、发现模式或失败设备仅保留说明。`plan.json` 和 `summary.json` 同时记录文件路径与命令文件 SHA-256；终端会打印脚本及设备报告目录。脚本是审批计划的文本导出，生成不代表已经执行，应用仍须现场重验；导出失败不会开始应用。

已有描述语义一致时保留原文：大小写和同类型接口别名（如 G/GE/Gi、SE/Smartrate-Ethernet）不会触发改写；名称、端口编号或速率变化仍产生候选变更。`topology.neighbor_name_prefixes` 可声明历史名称前缀；示例设置 `["AP-"]`，仅比较时容忍前缀，新描述仍按 `description_format` 生成。未知邻居名称/端口（如 `-`、`unknown`）保留为 `unverified` 问题，不使用 chassis ID 或现有描述猜测身份。MAC 是合法的 LLDP Port ID，有明确名称时保留该原始证据。

默认只读 `--plan`，清单可来自缓存，但邻居和当前描述读取现场。`--discover` 只读发现；`--apply` 显式执行本次现场生成的计划，先持久化 `plan.json` 和 SHA-256，再重验目标邻居身份与原描述，修改后回读符合预期才保存。YAML `mode: apply` 本身不授予写入权限。

```sh
bundle exec ruby examples/topology.rb --discover --name edge --exclude-name core --parallel 8
bundle exec ruby examples/topology.rb --plan --name-match glob --name 'edge-*' --limit 5
bundle exec ruby examples/topology.rb --plan --host 192.0.2.10
bundle exec ruby examples/topology.rb --apply --host 192.0.2.10
```

默认描述为 `To_<邻居名称>_<缩写端口>`，保留名称大小写，空格转为下划线。YAML 的 `description_format` 仅接受 `%{neighbor}`、`%{port}`，`abbreviate_ports` / `lowercase_ports` 控制端口格式；CLI 可用 `--description-format`、`--full-port-names`、`--lowercase-ports` 覆盖。报告区分 `missing_description`、`format_mismatch`、`content_mismatch`、`matches`。

邻居身份不完整、重复邻居、缺失接口或不安全描述的接口单独保留为待核实，其余已验证接口可继续生成部分计划；目标证据变化仍拒绝下发。部分规划/部分应用退出码为 1。不支持发现的设备明确跳过且不占 `--limit`，全无可发现设备非零。只读平台如 PAN-OS 有偏差时报告 `manual_required`。没有邻居的接口保持原描述，明确无邻居与发现失败分别报告。

## 进度、报告与退出码

默认人类可读结果，进度写 stderr；`--json` 将结果 JSON 写 stdout，配合 `--quiet` / `--no-progress` 关闭进度。`--verbose` 显示逐台事件，默认并发 4，范围 1–500，备份默认全量，抽样须显式 `--sample` 或 YAML 设置。

唯一私有批次目录保存计划、JSON/文本汇总、`events.jsonl` 和会话日志；拓扑文本报告包含逐接口当前/预期描述、原因及建议命令。设备条目包含状态、诊断和耗时，保存或关闭失败不会抹掉设备回执；拓扑中断会保存已经登记的设备结果。进度输出故障进入最终结果，不重放设备操作，不自动回滚其他设备。`--stdin-credentials` 读取一行凭据 JSON；备份执行及拓扑 apply 还需下一行 `RUN`。

退出码：0 完成（拓扑 plan 要求无偏差）；1 偏差或未完成；2 参数/清单/编排错误；130 中断。拓扑 discover 成功发现时允许有偏差仍返回 0。备份默认成功策略 `selected`，仅允许主动过滤和抽样跳过；未知厂商、缺少凭据、失败、部分结果或报告错误均非零。`verified` 还需服务器文件核验。

公开模板为 `backup.example.yml`；可复制到用户配置目录的 `backup.yml` 后填写本机策略。运行中的 `backup.yml` 不进入 gem，避免将现场地址发布到安装包。

```sh
cp examples/backup.example.yml examples/backup.yml
```

已有 `backup.yml` 时保留原文件，不重复复制。
