# 设备操作架构

一个公开连接器对象对应一台设备的一段会话，负责连接状态、命令执行和厂商档案。调用方仍使用 `device.running_config`、`device.backup(path:)`、`device.tftp_backup(...)`。运行配置是设备的基本能力，因此设备入口、不可变档案和公共采集流程放在 `device/`。`Operations` 承载备份、解析、邻居发现和接口描述计划等业务；已有文件的导出只读取本地备份，不建立设备连接。

| 层次 | 职责 | 位置 |
| --- | --- | --- |
| 设备会话 | 登录、命令交互、脚本和日志 | `engine/` |
| 设备 | 公开入口、不可变档案、配置采集和接口命名 | `device/` |
| 厂商组装 | 提示符、命令、交互、策略绑定及会话钩子 | `vendor/<厂商>.rb` |
| 公共配置采集 | 执行、完整性判断和旧钩子适配 | `device/running_config.rb`、`device/running_config/strategy.rb` |
| 厂商配置采集 | 清理文本、切换视图和检查响应 | `vendor/<厂商>/running_config.rb` |
| 接口文本 | 名称匹配、简称、描述和公共接口视图命令 | `device/interface_name.rb`、`device/interface_description.rb` |
| TextFSM 解析 | 选择模板，将命令或配置转为记录 | `operations/parse_output.rb`、`templates/` |
| 拓扑与描述计划 | 读取邻居及旧描述、生成命令、重验后下发 | `operations/topology.rb` |
| 本地备份 | 采集、比较哈希、原子保存并报告变化 | `operations/local_backup.rb` |
| 已存配置导出 | 不访问清单或设备，读取已有备份 | `operations/saved_config.rb` |
| 私有文件写入 | 以 `0600` 权限原子替换文件 | `operations/private_file.rb` |
| TFTP 备份 | 校验目标、执行导出、核对成功证据 | `operations/tftp_backup.rb` |
| TFTP 厂商策略 | 命令、提示、源文件、成功证据和目标名称 | `vendor/<厂商>/tftp_backup.rb` |
| 拓扑厂商策略 | 发现命令、解析证据、配置视图及特殊命令 | `vendor/<厂商>/topology.rb` |
| 清单规划 | 选择就绪设备、限制厂商数量、记录跳过原因 | `netdisco/planner.rb` |
| 清单计划 | 保存不可变快照，校验任务槽位、跳过原因和目标冲突 | `netdisco/plan.rb` |
| 批量执行 | 分派独立设备任务，隔离回调故障 | `netdisco/worker.rb` |
| 批量结果 | 汇总设备状态并保留报告故障 | `netdisco/batch.rb` |
| 设备集合 | 读取清单、执行本地或 TFTP 任务、写报告 | `netdisco/fleet.rb` |
| 设置 | 读取环境变量及 YAML 覆盖项 | `netdisco/settings.rb` |

## 业务约束

连接器独占一个会话。`Session` 串行执行登录和脚本，失败时关闭传输，不自动重放设备命令。`Result` 在后续步骤失败时仍保存已完成步骤。`RunningConfig` 每次采集创建一个新策略，同一策略负责响应检查、结果选择和清理。选择与清理在会话锁内经过现有设备钩子，子类覆盖后可调用 `super`。清理失败时也会解除临时绑定，其他 Fiber 的离线清理不能借用该策略。

采集命令匹配当前会话的完整提示符行，不以末尾单个 `#`、`>` 或 `]` 判断完成。PAN-OS 切换视图时保留已认证的设备身份。缺少最终提示符会使采集失败，旧备份保持不变；只有提示符或命令回显的响应属于 `:incomplete_configuration`，不是成功的空配置。PAN-OS 在 `show` 前后都检查候选配置差异。

`LocalBackup` 先采集再替换私有文件。TFTP 只确认设备报告的上传结果：策略去掉命令、应答和提示符回显后，检查明确的完成行；文件名或表示“即将上传”的进度文字不算成功。原始输出或终端渲染文本中的失败证据优先于成功文字。

`Topology` 读取邻居和旧描述，冻结计划，要求显式确认，下发前重验全部证据，重建命令，并在执行后回读。重验、下发、回读期间持有会话操作租约；只有所属线程和 Fiber 能顺序执行脚本，其他调用、关闭请求和命令回调中的重入均返回 `SessionBusy`。租约只保护一个连接器实例，不是设备端或跨进程锁。

`Session` 使用 `Mutex#try_lock`，让竞争调用立即失败而不等待长时间设备命令。租约同时记录线程与 Fiber；同线程的另一个 Fiber 不能借用。`@performing` 还阻止命令回调嵌套执行脚本。可重入锁本身无法区分“租约内顺序执行脚本”和“命令回调嵌套执行脚本”；替换锁实现时仍须保留这层业务判断。

`Fleet` 区分跳过、失败、成功和保存成功但关闭失败的结果；回调和报告故障不会丢弃设备结果。邻居表头可以证明空表，但未知或部分解析的数据行不能证明完整发现。诊断同时检查原始输出与终端渲染文本，防止颜色控制符隐藏错误或回车覆盖失败信息。计划重验比较完整邻居身份，包括可用的机箱 ID，公开证据哈希结构不变。PAN-OS 配置采集保留引号内的多行文本；接口描述模板只支持单行备注，未闭合引号会返回 `ParsingError`。

`Worker` 按线程完成顺序接收终止通知，设备结果仍写入原清单槽位。任一线程中断时，调用方无需等待先创建的慢线程；创建后续线程失败时，也会停止并等待已启动的任务清理资源。普通设备故障继续转换为逐台结果，回调故障单独记录。

`Planner` 先按厂商采样，再按实际 TFTP 文件名排除覆盖冲突，保留采样顺序中的首台设备。未入选设备仍标记为 `sample_limit`，只有入选后目标重名才标记为 `remote_filename_collision`。`Plan#validate!` 校验任务与清单的对应关系；调用方传入或通过 `with` 修改的计划也必须在读取凭据、创建目录及设备 I/O 前通过校验。冲突规则适用于全部厂商，包括不同地址规范化后产生相同文件名的情况。

## Expect 语义与 Ruby 边界

[Tcl Expect 手册](https://core.tcl-lang.org/expect/doc/trunk/expect.man)定义有序匹配、`exp_continue -continue_timer`、缓冲区消费、EOF，以及分离的关闭和等待职责。[匹配循环](https://github.com/tcltk-depot/expect/blob/main/expect.c)在继续匹配时保留截止时间，[进程处理](https://github.com/tcltk-depot/expect/blob/main/exp_command.c)负责等待子进程并重试中断。这些是参考语义；`net-connector` 是设备操作库，不实现 Tcl 解释器或完整 Expect API。

| 关注点 | 连接器约束 | 负责对象 |
| --- | --- | --- |
| 匹配 | 先识别连接失败，再处理交互，最后匹配提示符；提示符匹配必须消费字节 | `ResponseReader` |
| 时间 | 命令写入和提示应答共用单调时钟截止时间，进度与分页不延长它 | `Session`、`ResponseReader` |
| 缓冲区 | 输出上限由 `max_output_bytes` 控制，流式匹配保留 32 KiB 未匹配尾部 | `Transports::Pty`、`ResponseReader` |
| EOF | 返回 `ConnectionClosed`，保留先前步骤，关闭会话 | `ResponseReader`、`Execution`、`Session` |
| 资源 | 通过 `expect-pty#hard_close` 管理子进程；设置或刷新失败仍释放日志文件 | `Transports::Pty`、`Log` |
| 人工交互 | 人工接管结束自动会话，后续操作需重新连接 | `Session` |
| 并发 | 单个脚本或多脚本操作独占会话，回调不能重入；独立设备由限量线程池执行 | `Session`、`Netdisco::Worker` |

提示符和交互标记是 Ruby 正则表达式，应短到能放入未匹配尾部；流式适配器不支持需要无限长历史的模式。收集输出的上限与匹配窗口上限不同。终端渲染器只处理常见行编辑控制符，不是完整屏幕终端模拟器。`Profile#terminal_size` 使用 `[宽, 高]`，PTY 适配器转换为 Ruby 的 `[行, 列]`。

Ruby 对象显式拥有资源并使用关键字参数。`Profile` 提供有限声明入口，厂商策略负责差异行为。公开方法、厂商钩子、结果对象和 CLI JSON 字段延续现有契约；内部不做运行时方法注入，也没有工作流 DSL。

## 厂商能力

`device.supports?(capability)` 读取档案与基于方法的采集命令，不建立传输连接或策略实例。接受 `:running_config`、`:save_config`、`:backup`、`:tftp_backup`、`:neighbors`、`:interface_descriptions`、`:interface_description_changes`；未知名称返回 `false`。它只表明实现了能力，不验证设备授权或固件兼容性。

| 厂商 | 采集及本地备份 | 保存 | TFTP | 邻居 | 描述读取 | 描述计划及下发 |
| --- | --- | --- | --- | --- | --- | --- |
| H3C | 是 | 是 | 是 | 是 | 是 | 是 |
| H3C 无线 | 是 | 是 | 是 | 是 | 是 | 是 |
| Cisco IOS / IOS XE | 是 | 是 | 是 | 是 | 是 | 是 |
| Cisco NX-OS | 是 | 是 | 是 | 是 | 是 | 是 |
| Radware Alteon | 是 | 是 | 是 | 否 | 是 | 否 |
| PAN-OS | 是 | 否 | 是 | 是 | 是 | 是 |
| 华为 | 是 | 是 | 是 | 否 | 否 | 否 |
| 山石 | 是 | 是 | 是 | 是 | 是 | 是 |

`Profile` DSL 声明静态命令、提示符、交互和策略绑定。配置、TFTP、拓扑规则位于各自的 `vendor/<厂商>/` 下；公共业务负责校验、执行和结果语义。相同规则直接复用：NX-OS 使用 IOS 拓扑规则，H3C 无线继承 H3C，H3C、华为、Radware 使用公共终端渲染配置策略。目录存在不意味着必须复制一份规则，子类可只覆盖需要变化的绑定。

```mermaid
flowchart LR
  A[厂商 profile 声明块] --> B[Profile.define]
  B --> C[Profile::Builder]
  C --> D[命令、提示符、分页和策略字段]
  D --> E[Builder#build]
  E --> F[Profile.new 校验并冻结]
```

`device/profile.rb` 中的 `Profile` 是不可变值对象；`device/profile/builder.rb` 保存可变声明 DSL 及字段构造器。`Profile.define` 复制父档案，运行一次厂商声明块，再由 `build` 校验并冻结新档案。子类覆盖规则不会污染父类。TFTP 或拓扑绑定设为 `nil` 会关闭对应能力；配置采集绑定为 `nil` 时使用默认策略，空采集命令列表则关闭采集。

例如，型号变体只替换 TFTP 流程：

```ruby
require "net/connector"
require "net/connector/vendor/cisco_ios"

class VariantTransfer < Net::Connector::CiscoIos::TftpBackup
  # 只覆盖该型号需要变化的方法，并遵守 Strategy 接口。
end

class VariantRouter < Net::Connector.vendor_class(:cisco_ios)
  profile do
    tftp_strategy VariantTransfer
  end
end

router = VariantRouter.new(host: "192.0.2.10", username: "operator")
router.supports?(:tftp_backup) # => true，不连接设备
```

配置采集可把 `running_config_strategy` 绑定到 `Net::Connector::RunningConfig::Strategy` 子类。策略定义清理、结果步骤、视图提示符和逐响应检查。PAN-OS 候选差异只影响配置采集；直接 `execute("show config diff")` 仍返回该命令输出。静态命令列表留在档案中。已有的 `collect_config`、`clean_config` 和受保护的 `config_result_step` 钩子仍可覆盖并调用 `super`。`Base` 负责通用脚本与锁内回调，不决定配置是否完整。

拓扑策略通过 `topology_strategy YourStrategy` 绑定。类方法 `supports?` 声明三种拓扑能力，实例方法提供命令、模板、输出完整性和接口拼写。厂商使用自定义清单标签时，还须通过 `neighbor_template` 提供 TextFSM 模板，因为内置索引只匹配已有厂商键。确认、证据复核及回读仍由公共 `Topology` 完成。

业务操作针对单个连接器构造，并提供 `call`。TFTP 策略只处理厂商传输差异，公共操作统一成功和失败规则。生成的文件名经过 `TftpTarget` 校验及长度限制；带作用域的 IPv6 地址会转为安全 ASCII 标记，特别长的地址使用稳定 SHA-256 标记。原本合法的文件名保留拼写，只有整体过长才缩短清单名称。TFTP 返回值表示设备报告上传完成，服务器文件核对仍由调用方负责。

TFTP 策略的类方法 `filename(host, label: nil)` 是不产生 I/O 的命名接口，默认使用 `file_extension` 声明的扩展名。Netdisco 只清理清单名称，不再维护厂商扩展名或固定文件名的分支。Radware 和山石分别声明 `tgz`、`dat`，PAN-OS 返回固定名称。旧自定义策略未实现该类方法时仍使用通用 `cfg` 名称。H3C、华为继承公共 `Tftp::FileUpload`，共用上传脚本、默认源文件名和完成证据；各自只负责取得并校验源文件。

验收入口是 `script/ci`，也可用 `bundle exec rake release:check`。它检查源码、可用 Git 历史和 gem 内容中的敏感数据，执行 Ruby 与工作流 lint、完整测试，并在隔离 gem 目录及最小 Bundler 应用中安装。真实本地 PTY 烟测覆盖厂商加载、配置采集、打包模板和 CLI，不接触网络设备。初次下载依赖和工具需要联网，详见[验证文档](VERIFICATION.md)及[发布文档](RELEASING.md)。

## 加载与兼容路径

`require "net/connector"` 只加载设备 API 和引擎，不预先加载厂商规则或 TextFSM。每个厂商入口只组装自身规则和公共父类；解析操作按需加载。更底层的调用方可用 `require "net/connector/engine/core"`，不加载设备定义、业务操作或厂商规则。`engine/base`、`engine/profile`、`engine` 保留为旧入口的转发路径。

旧的 `Operations::RunningConfig`、`Operations::RunningConfig::<Vendor>`、`Operations::Tftp::<Vendor>`、`Operations::Topology::<Vendor>` 常量和 require 路径都转发到同一实现类，不维护两份逻辑。已有公开结果常量也通过 autoload 保留。新增厂商代码应直接使用厂商目录下的类。

## 接口描述规则

原始 `Neighbor` 字段和计划证据完整保留发现值。`InterfaceName.key` 用于匹配本机接口别名与运行配置名称；`InterfaceName.configuration` 保留配置命令的接口展开规则。`InterfaceName.short` 只决定描述里对端接口的显示形式，绝不替换本机下发命令中的接口名。

`InterfaceDescription.format(neighbor, abbreviate: true, lowercase: false)` 是各厂商默认计划共用的纯函数，生成 `To <名称> <接口>`。已知接口族会缩写，并保留原有大小写：Ethernet/Eth 为 Eth，GigabitEthernet/GE/Gi 为 Gi，Ten-GigabitEthernet/TenGigabitEthernet/XGE/Te 为 Te，FastEthernet/Fa 为 Fa，port-channel/Po 为 Po。端口编号与子接口后缀保留。`ge-0/0/1`、`100GE1/0/1`、`Port 12` 等未知形式默认不变；这是有限映射，不声称识别全部厂商命名。

默认建议因此从 `To peer Ethernet1/2` 变为 `To peer Eth1/2`。`abbreviate: false` 保留原拼写，`lowercase: true` 仅将对端接口改为小写。自定义代码块拿到原始邻居，可生成完整描述。输出仍必须经过 80 字节及字符校验、证据复核、确认和回读。

`InterfaceDescription.commands(interface:, description:, leave: "exit")` 为 IOS/NX-OS 和山石分别生成 `interface`、`description`、退出命令；H3C 使用 `leave: "quit"`。进入配置视图和保存配置仍由厂商负责。PAN-OS 保留 `set network interface ... comment`、`commit` 及延长的提交超时。公共命令构造器不连接设备，也不能绕开已审核的拓扑计划。

## 敏感命令的生命周期

一个临时脱敏范围贯穿命令准备、收发、厂商后处理、用户回调和错误归一化。后续查询复用外层范围，`ensure` 在结束时清除临时秘密。敏感错误保留类型、代码、阶段和已完成步骤，但隐藏可能包含部分秘密的消息、输出及底层回溯。显式结果数据仍是原始数据。直接与流式脱敏先匹配真实秘密，包括含字面量 `[REDACTED]` 的秘密，再保留已有标记。

## 本地备份标识与旧文件

批量备份只用规范化管理地址命名为 `<IP>.txt`，IPv6 的 `:` 改为 `_`。清单名称仍保留在结果元数据及 TFTP 文件名中。`SavedConfig` 优先使用规范文件；缺失时只接受唯一的旧版 `<名称>-<IP>.txt`。匹配多个旧文件时明确失败，不按修改时间随意选择。

首次成功的规范备份会与唯一旧文件的哈希比较，旧文件保持不变，并报告 `changed` 或 `unchanged`。采集失败不会创建规范文件。连接设备前先拒绝符号链接和非普通文件。旧文件存在歧义时，应保留原件，由操作人员核对后把当前正确配置放到规范路径，再恢复备份或导出。

## 公开契约与 Rails 接入

应用代码优先使用 `Net::Connector.open/build`、`Base` 的公开设备方法、`Command`、`Script`、结果对象，以及 `Netdisco::Fleet`。厂商扩展使用 `Profile` DSL 和文档中列出的策略接口；`Profile::Builder`、`Session` 的状态字段、工作线程调度及解析辅助方法属于内部实现。兼容 require 路径只转发到当前实现，新增扩展使用厂商目录下的类。项目仍处于 0.x，公开契约的变更会在更新记录中说明。

gem 不依赖 Rails，也不自动创建数据库模型或管理应用的连接池。`logger: Rails.logger` 由应用持有，连接器只追加设备标记，不修改或关闭它。数据库报告通过 `ResultStore::Database` 注入仓储，写报告发生在调用线程中；逐设备凭据解析、连接器工厂和回调则运行在工作线程中。

在 Rails 内调用涉及模型、自动加载或应用状态的线程代码时，应由应用用 `Rails.application.executor.wrap` 包住相应调用。仅在外层包住 `fleet.backup_all` 不会覆盖子线程。例如，凭据解析器可以写为：

```ruby
credentials = lambda do |device|
  Rails.application.executor.wrap do
    DeviceCredential.for_host(device.host).connection_settings
  end
end
```

这里的 `DeviceCredential` 是应用自己的模型。涉及 Rails 的工厂、回调或自定义连接器方法也遵循同一规则；Rails 的 Executor 负责应用代码的执行边界及数据库连接回收。不要在工作线程中使用 Reloader 包住整批任务。需要每台设备独立重试和调度时，可在应用的 Active Job 中调用单设备 API。具体规则见 [Rails 线程与代码执行指南](https://guides.rubyonrails.org/threading_and_code_execution.html)。
