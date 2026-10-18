# 配置备份与拓扑示例

这些脚本使用本仓库的 `CLI::Backup`、`CLI::Topology` 与设备接口，支持 Ruby 3.2 或更新版本。先在项目根目录安装依赖，再通过项目 Bundler 运行：

```sh
bundle install
bundle exec ruby examples/backup.rb --help
bundle exec ruby examples/backup_tftp.rb --help-all
bundle exec ruby examples/topology.rb --examples
```

也可以在 `examples/` 中运行 `bundle exec ruby backup.rb --help`。脚本沿用调用方选择的 RubyGems/Bundler 环境，不自动切换 Gemfile 或搜索相邻工作树。普通 `ruby` 使用已安装的 gem，因此需要安装包含这些接口的版本。

示例入口测试统一位于 `test/`，并纳入 `bundle exec rake test`。单独运行示例测试：

```sh
bundle exec ruby -Itest -e 'Dir["test/examples*_test.rb"].sort.each { |file| require_relative file }'
```

`boot.rb` 直接加载库、读取项目根目录 `.env`，再将工作目录切换到项目根目录。已有进程环境变量优先于 `.env` 同名值。三个入口通过库的 `environment_defaults: true` 启用 **CLI > YAML > 环境默认值**；配置合并由 `CLI::Options.settings` 负责，凭据留在环境中，YAML 不接受密码。正式 CLI 保留既有的环境覆盖规则。库本身不加载 `.env`、不切换目录、不退出宿主。CLI/YAML 中的相对配置和输出路径以项目根目录为准；进程启动前设置的 `NC_CONFIG` 先按启动目录转为绝对路径。

## 入口与配置

| 文件 | 用途 |
| --- | --- |
| `backup.rb` / `backup.yml` | 全量运行配置采集与本地备份 |
| `backup_tftp.rb` / `backup.yml` | 批量原生 TFTP 导出及可选服务器核验/归档 |
| `topology.rb` / `topology.yml` | 邻居发现、描述审计、只读规划和显式应用 |
| `inventory.yml` | PostgreSQL 查询、缓存、筛选及备份策略 |

备份入口默认注入同目录 `backup.yml` 和 `backups/`；拓扑入口注入 `topology.yml` 和 `topology_reports/`。YAML 和显式 CLI 可覆盖默认目录。首次找不到指定配置时，创建无凭据、私有权限的 YAML 后停止，检查后再次运行；已有文件不覆盖。TTY 会询问是否交互配置，`--interactive` / `--non-interactive` 显式控制，EOF 或取消不发布半份配置。非终端默认不消费标准输入。`--help`、`--help-all`、`--examples` 均不读取清单或创建配置。

以下命令从项目根目录运行：

```sh
bundle exec ruby examples/backup.rb --help
bundle exec ruby examples/backup.rb --examples
bundle exec ruby examples/backup.rb --plan --host 192.0.2.10
bundle exec ruby examples/backup.rb --inventory-only --name edge --cache-only
bundle exec ruby examples/backup.rb --hosts 192.0.2.0/24 --exclude-name wlc --concurrency 8
bundle exec ruby examples/backup.rb --sample 3 --verbose
bundle exec ruby examples/backup.rb --config examples/inventory.yml --plan
```

## 清单、凭据与缓存

只选择 Netdisco 清单已有设备，不展开网段或扫描地址。地址支持精确 IP、CIDR、完整范围和 IPv4 末段简写 `192.0.2.10-20`，IPv6 范围使用完整端点。地址、名称和厂商条件取交集，排除优先。名称忽略大小写，支持 `contains`、`prefix`、`glob`；多个同类 CLI 参数取并集，覆盖同类 YAML 策略。`--host` 与 `--hosts` 互斥。

```sh
bundle exec ruby examples/backup.rb --plan --hosts 192.0.2.10-20 --name edge --exclude-name core,wlc
bundle exec ruby examples/topology.rb --inventory-only --name-match glob --name 'edge-*' --vendor h3c --cache-only
```

凭据仍来自环境、显式 CLI 或调用方注入，不写入 YAML。单设备 TFTP 使用 `backup_tftp.rb --host IP`，与批量执行共用凭据、连接策略、核验和报告。HTTP 使用 `ND_URL`、`ND_USERNAME` / `ND_PASSWORD` 或 `ND_API_KEY`；PostgreSQL 使用 `ND_DB_HOST`、`ND_DB_NAME`、`ND_DB_USER`、`ND_DB_PASS`。设备使用 `NC_DEVICE_USERNAME`、`NC_DEVICE_PASSWORD`，可选 `NC_ENABLE_PASSWORD` 及按厂商凭据覆盖。PostgreSQL 使用项目已声明的 `pg` 驱动；示例 `.env` 不进入版本库。环境默认模板见 `.env.example`，实际加载位置仍为项目根目录 `.env`。公开设置如 `NC_BACKUP_DIRECTORY`、`NC_HOST_KEY_POLICY`、`NC_KNOWN_HOSTS`、`NC_TFTP_HOST`、`NC_TFTP_ROOT` 通过库的 `environment_defaults: true` 作为默认值，可由对应 YAML 字段覆盖；结构化映射使用 JSON，列表使用逗号分隔；YAML 声明列表或映射字段时整体覆盖该字段。旧 `NETDISCO_URL/USERNAME/PASSWORD` 应改为 `ND_URL/USERNAME/PASSWORD`，`TFTP_ROOT` 应改为 `NC_TFTP_ROOT`，不改变赋值内容。

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

## 拓扑发现与应用

默认只读 `--plan`，清单可来自缓存，但邻居和当前描述读取现场。`--discover` 只读发现；`--apply` 显式执行本次现场生成的计划，先持久化 `plan.json` 和 SHA-256，再重验目标邻居身份与原描述，修改后回读符合预期才保存。YAML `mode: apply` 本身不授予写入权限。

```sh
bundle exec ruby examples/topology.rb --discover --name edge --exclude-name core --concurrency 8
bundle exec ruby examples/topology.rb --plan --name-match glob --name 'edge-*' --limit 5
bundle exec ruby examples/topology.rb --plan --host 192.0.2.10
bundle exec ruby examples/topology.rb --apply --host 192.0.2.10
```

默认描述为 `To_<邻居名称>_<缩写端口>`，保留名称大小写，空格转为下划线。YAML 的 `description_format` 仅接受 `%{neighbor}`、`%{port}`，`abbreviate_ports` / `lowercase_ports` 控制端口格式；CLI 可用 `--description-format`、`--full-port-names`、`--lowercase-ports` 覆盖。报告区分 `missing_description`、`format_mismatch`、`content_mismatch`、`matches`。

邻居身份不完整、重复邻居、缺失接口或不安全描述的接口单独保留为待核实，其余已验证接口可继续生成部分计划；目标证据变化仍拒绝下发。部分规划/部分应用退出码为 1。不支持发现的设备明确跳过且不占 `--limit`，全无可发现设备非零。只读平台如 PAN-OS 有偏差时报告 `manual_required`。没有邻居的接口保持原描述，明确无邻居与发现失败分别报告。

## 进度、报告与退出码

默认人类可读结果，进度写 stderr；`--json` 将结果 JSON 写 stdout，配合 `--quiet` / `--no-progress` 关闭进度。`--verbose` 显示逐台事件，默认并发 4，范围 1–50，备份默认全量，抽样须显式 `--sample` 或 YAML 设置。

唯一私有批次目录保存计划、JSON/文本汇总、`events.jsonl` 和会话日志；拓扑文本报告包含逐接口当前/预期描述、原因及建议命令。设备条目包含状态、诊断和耗时，保存或关闭失败不会抹掉设备回执；拓扑中断会保存已经登记的设备结果。进度输出故障进入最终结果，不重放设备操作，不自动回滚其他设备。`--stdin-credentials` 读取一行凭据 JSON；备份执行及拓扑 apply 还需下一行 `RUN`。

退出码：0 完成（拓扑 plan 要求无偏差）；1 偏差或未完成；2 参数/清单/编排错误；130 中断。拓扑 discover 成功发现时允许有偏差仍返回 0。备份默认成功策略 `selected`，仅允许主动过滤和抽样跳过；未知厂商、缺少凭据、失败、部分结果或报告错误均非零。`verified` 还需服务器文件核验。
