# Topsec、Fortinet 与 Juniper

三个平台使用 `Vendor` 注册表、Profile 和现有会话执行器，均支持 SSH/Telnet 命令执行、运行配置采集与本地私有备份。能力声明区分设备系统，不能仅凭品牌把 FortiMail、ScreenOS 等产品映射到 FortiOS 或 Junos。

| 平台键 | 系统与登录视图 | 采集命令 | 保存 | 原生远端备份 | 拓扑读取 |
| --- | --- | --- | --- | --- | --- |
| `topsec` | TopOS 防火墙，`TopsecOS#` 或 `#` 管理视图 | `show-running nostop` | 未开放 | 使用本地采集备份 | 未开放 |
| `fortinet` | FortiGate/FortiOS，当前账号授权的根或 VDOM 视图 | `show full-configuration` | `execute cfg save` | TFTP `execute backup full-config tftp` | LLDP 邻居、当前视图接口描述 |
| `juniper` | Junos OS，`user@host>` 操作视图 | `show configuration \| display set \| no-more` | 已提交配置已持久化；不隐式提交候选库 | FTP/SCP `show configuration \| save` | LLDP 邻居、物理接口及逻辑单元描述 |

这些能力通过合成会话、解析样例和安装检查验证，尚无真实设备验收记录。Topsec 只实现有检索依据的 TopOS 配置读取方言；其他系列需依据其 CLI 手册接入，不能套用 Cisco 的命令。

## Junos 原生 FTP/SCP 导出

```ruby
Net::Connector.open(:juniper, host: "192.0.2.1", username: "audit",
                    password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  receipt = device.remote_backup(host: "backup.example", path: "site/srx.cfg",
                                 username: "archive", protocol: :scp,
                                 password: ENV["NC_ARCHIVE_PASSWORD"])
  puts "#{receipt.protocol}: #{receipt.server}/#{receipt.path}"
end
```

`protocol:` 接受 `:scp`（默认）或 `:ftp`。`host:` 是 IPv4 地址或 DNS 名称，`path:` 是无空格、无目录穿越的相对路径；账号单独传入，不接受含密码的 URL。`password:` 可省略以使用设备端已有认证配置，提供时仅在密码挑战中发送一次并脱敏。SCP 服务器主机密钥应事先在设备上建立信任，连接器不自动回答接受主机密钥的询问。FTP 为明文协议。

导出保持在操作视图，`show configuration` 读取当前已提交配置。只有目标 URL 完全一致且写出行数大于零的 `Wrote ... lines of output to '...'` 完成行才生成 `RemoteBackup::Receipt`。回执标记 `verification: :device_reported`，不声称已读取远端文件或计算摘要。无完成证据时抛出 `transfer_unconfirmed`，设备错误保持原异常；上传确认后的收尾失败抛出 `RemoteBackup::CompletionError`，`error.receipt` 保留上传事实，不自动重传。

`device.supports?(:remote_backup)` 可离线检查原生 FTP/SCP 导出能力。目前由 Junos 实现；Fleet/CLI 的本地备份与 TFTP 批次接口保持各自用途。Junos `file copy` 文档列出 FTP、HTTP、HTTPS、SCP，不提供可直接套用的 TFTP 上传接口；`save` 配置模式导出候选内容，`commit` 激活候选库，均不能冒充只读的已提交配置备份。自动接口描述提交暂未开放。

## FortiOS 视图、分页与版本

采集使用当前账号授权的视图；VDOM 管理账号得到所属 VDOM 的配置，不能把它当成整个设备的全局归档。分页用空格应答，不通过 `config system console` 修改设备的持久设置。`execute cfg save` 为显式保存请求；常见自动保存模式下无需另存。

TFTP 导出包括默认值，不接受 `source_file:` 或 `vrf:`。成功必须包含完整的 `Send config file to tftp server OK.` 行；仅出现提示符、命令回显、通用进度或其他传输成功词不算完成。`TftpReceipt` 与已有厂商一致，默认仅为设备报告，服务器文件核验仍由现有 TFTP 核验流程负责。

LLDP 查询先读取 `get system status`，明确解析版本后选择命令：7.6.2 及以前使用 `diagnose lldprx neighbor`，7.6.3 起使用 `diagnose lldp rx neighbor`。无法识别版本时直接报解析错误，不猜测命令。接口行数量与解析记录必须一致，空响应不会被当作零邻居。

Junos LLDP 使用 `show lldp neighbors detail | no-more`，逐个本地接口块核对记录。残缺记录及只有标题的输出会报错；接口描述从已提交的 set 配置中读取，逻辑单元用 `接口.单元号` 独立返回，保留 `ge-`、`xe-`、`ae` 等原接口身份。

## 命令依据

- [FireMon TopSec 配置获取接口](https://docs.firemon.com/feature/Content/ADMINISTRATION/DEVICE/Offline_Import_or_Batch_Configs/Additional_Devices.htm)：TopSec 的运行配置使用 `show-running nostop`，启动配置使用 `show nostop`，两者不混用。
- [Fortinet 配置 TFTP 备份](https://community.fortinet.com/fortigate-3/technical-tip-backup-configuration-files-via-tftp-99896)：FortiGate `execute backup full-config tftp` 参数。
- [FortiOS execute cfg](https://docs.fortinet.com/document/fortigate/7.6.5/cli-reference/169686240/execute-cfg)：显式保存命令。
- [Fortinet LLDP 邻居查询](https://community.fortinet.com/fortigate-3/technical-tip-use-lldp-on-fortigate-to-verify-connected-switches-210084)：7.6.3 命令改名及邻居输出字段。
- [Juniper Junos 升级前备份指南](https://www.juniper.net/documentation/us/en/software/junos/srx-upgrade/srx-upgrade.pdf)：操作视图 `show configuration | save` 导出已提交配置。
- [Juniper save 配置模式语义](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/ref/statement/save-cli-config.html)：配置模式的层级导出与远端 SCP。
- [Juniper file copy 协议](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/ref/command/file-copy.html)：支持的远端文件传输 URL。
- [Juniper LLDP 邻居字段](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/ref/command/show-lldp-neighbors.html)：接口、机箱、端口和系统名字段，`detail` 选项要求 Junos 19.1R2 或以上。

## 拓扑读取能力对齐

Huawei VRP 通过 `display lldp neighbor brief` 提供 LLDP 邻居，运行配置提供接口描述。简表不包含机箱 ID，邻居的 `chassis_id` 保留为空；接口类型与编号之间的空格在返回值中保留，在配置身份关联时移除。没有已验证的提交与保存阶段，因此只开放读取。

FortiOS 从既有 `show full-configuration` 结果中读取顶层 `config system interface` 的 `description`，不把 `alias` 当作描述，不切换 VDOM 或全局视图。嵌套 VDOM 接口表、多个顶层接口表、缺少 next/end 或未闭合描述会报解析错误。输入按标准 CLI 的四空格缩进组织；不对其他导出格式作静默猜测。

- [Huawei LLDP 邻居简表](https://info.support.huawei.com/hedex/api/pages/EDOC1100277650/AZM1016J/04/resources/command/yunshan/LLDPDISPLAYNEIBRIEF%28LLDPOM%29.html)：查询视图、字段及端口拼写。
- [Huawei 当前接口配置](https://info.support.huawei.com/hedex/api/pages/EDOC1100363264/AEN0403J/05/resources/command/yunshan/BUILDRUNINTERFACE1%28CLIOM%29.html)：接口块及生效配置的范围。
- [FortiOS 接口配置结构](https://docs.fortinet.com/document/fortigate/7.4.4/cli-reference/317104469/config-system-interface)：description、alias 与 IPv6 等嵌套配置。
- [Junos 物理接口与逻辑单元描述示例](https://www.juniper.net/documentation/en_US/day-one-books/DayOne-Intro-SRv6.pdf)：物理描述与 unit 描述的独立配置层级。
