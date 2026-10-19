# TextFSM 模板组织

模板只描述设备输出的记录结构，不负责连接、命令执行、完整性判断或配置变更。厂商策略负责选择模板并核对记录数量，公共 TextFSM 适配器负责严格 UTF-8 与终端文本边界。

## 目录与命名

`lib/net/connector/textfsm/` 统一采用 `<平台>/<完整命令名>[_格式变体].textfsm`。命令使用小写，空格、连字符和路径分隔符转为下划线；不使用缩写命令、字段用途名或额外的命令子目录。管道的输出格式选项保留为命令词，纯分页控制 `no-more` 不进入文件名。

例如，`show running-config` 对应 `show_running_config.textfsm`，`display current-configuration` 对应 `display_current_configuration.textfsm`，`/cfg/dump` 对应 `cfg_dump.textfsm`，`show configuration | display set` 对应 `show_configuration_display_set.textfsm`。PAN-OS 配置视图的命令是 `show`，其 set 输出对应 `palo_alto/show.textfsm`。H3C 同一命令的列序由同一模板按表头切换状态。

| 路径 | 输入与用途 |
| --- | --- |
| `cisco/show_cdp_neighbors_detail.textfsm` | IOS 的详细 CDP 邻居输出 |
| `cisco/show_running_config.textfsm` | IOS 运行配置中的接口和描述 |
| `cisco_ios/show_ip_interface_brief.textfsm` | IOS 的接口、IP 地址与状态摘要 |
| `cisco_nxos/show_cdp_neighbors_detail.textfsm` | NX-OS CDP 详细邻居块 |
| `cisco_nxos/show_running_config.textfsm` | NX-OS 运行配置中的接口和描述 |
| `cisco_nxos/show_ip_interface_brief.textfsm` | NX-OS 多 VRF 接口、IP 及 protocol/link/admin 状态 |
| `h3c/display_current_configuration.textfsm` | Comware 运行配置中的接口和描述 |
| `h3c/display_lldp_neighbor_information_list.textfsm` | 按表头识别名称首列或本地接口首列的 LLDP 列表 |
| `huawei/display_lldp_neighbor_brief.textfsm` | VRP LLDP 邻居简表，保留端口类型与编号之间的空格 |
| `huawei/display_current_configuration.textfsm` | VRP 运行配置中的接口和描述 |
| `hillstone/show_configuration_running.textfsm` | StoneOS 运行配置中的接口和描述 |
| `hillstone/show_lldp_neighbor_information.textfsm` | StoneOS 的 LLDP 邻居表 |
| `palo_alto/show.textfsm` | PAN-OS set 格式中的接口和备注 |
| `palo_alto/show_lldp_neighbors_all.textfsm` | PAN-OS 按接口分块的 LLDP 邻居输出 |
| `radware/cfg_dump.textfsm` | Alteon 配置转储中的端口名称 |
| `fortinet/show_full_configuration.textfsm` | 当前视图顶层接口表的描述，跳过嵌套表 |
| `fortinet/diagnose_lldp_rx_neighbor.textfsm` | FortiOS 改名前后 LLDP 邻居查询的共同输出 |
| `juniper/show_lldp_neighbors_detail.textfsm` | Junos LLDP 详细邻居块 |
| `juniper/show_configuration_display_set.textfsm` | Junos 已提交 set 配置中的物理接口与逻辑单元描述 |

H3C Wireless 沿用 H3C 模板。H3C 邻居策略与通用命令解析共用按表头切换列序的模板；未知表头直接拒绝，不尝试多个模板后采用碰巧解析出的部分结果。

## 索引与显式选择

根目录的 `index` 保持 TextFSM 的 `Template, Vendor, Command` 格式。Template 使用相对资源根目录的路径，Vendor 是连接器平台标识，Command 是命令匹配规则。内置索引的 Vendor 与 Command 均使用 `\A...\z` 完整匹配，防止前缀厂商名称及带额外命令片段的输入误选模板。一个共享模板可以被多个平台索引项引用。

```ruby
parser = Net::Connector::TextFSM.new
rows = parser.call(output, vendor: :cisco_ios, command: "show ip interface brief")
interfaces = parser.call(config, template: "cisco/show_running_config.textfsm")
```

命令索引覆盖内置配置及邻居模板；H3C 列序在模板状态机内选择。模板本身只解析记录，厂商策略仍负责表头、完整性及作用域校验。调用方也可以提供独立的 `template_dir:`，其索引和路径遵循相同规则。

## 修改与验证

修改模板时保留设备命令和字段语义，使用对应设备输出夹具核对记录。空结果不能代替未知或部分输出；完整性约束仍由拓扑等领域策略维护。`net-connector.gemspec` 递归收录模板，包检查验证每个资源的字节和路径，安装冒烟测试从已安装 gem 执行解析，避免源码目录掩盖资源遗漏。

## NX-OS 输出边界

NX-OS 模板独立放在 `cisco_nxos/`，CDP 按邻居块清理状态并与设备块数量核对，残缺块不能借用下一条记录的字段。接口描述在空行或下一个顶层配置段结束，防止 route-map 等后续段落的描述覆盖接口描述。IP 接口摘要保留 `VRF`、`INTERFACE`、`IP_ADDRESS`、`PROTOCOL`、`LINK_STATUS`、`ADMIN_STATUS` 六个字段；`show ip interface brief` 与带 `vrf` 参数的命令共用此模板。

输出字段参考 [Cisco NX-OS CDP 命令](https://developer.cisco.com/docs/nx-api-cli-reference-for-the-cisco-nexus-7000-series-platform/cdp-commands/)与 [Cisco Nexus IP 接口摘要](https://developer.cisco.com/docs/cisco-nexus-3000-and-9000-series-nx-api-rest-sdk-user-guide-and-api-reference-release-103x/querying-a-summary-of-ip-interface-status-and-configuration-information/)。测试使用脱敏合成输出，不代表真实设备及所有固件均已验证。

## 描述字段的词法与业务值

带引号的描述字段在模板中保留完整词法文本，`Interfaces::QuotedText` 负责还原引号与转义，并将不完整字段转为不含原文的领域错误。Junos、FortiOS、PAN-OS 与 Radware 使用同一解码边界；是否拆分无引号文本由厂商策略明确指定。接口不存在描述语句时可返回空描述，`description ""` 等显式空字符串也有明确含义；缺少值的 description/comment/name 语句则是残缺输入，不能被默认空字段掩盖。
