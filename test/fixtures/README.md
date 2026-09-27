# 厂商策略证据索引

本目录、`test/support/*_fixture.rb` 和下列测试中的内联回显均用于离线协议回归。
除子目录说明明确引用的官方命令示例外，来源是 v0.4.1 初始工作树中的合成测试，
本轮整理日期为 2026-09-27。真实型号、固件范围、现场采集日期及现场验证均为
**unknown**。没有真实设备配置、凭据或上传；地址使用文档地址，故障秘密在测试内生成。
设备名、接口和文件名只是样本标识，不构成型号/站点支持声明。

| 契约 / 格式 | 现有正例、负例和边界证据 |
| --- | --- |
| 能力查询无 I/O、继承/禁用/自定义策略 | `capabilities_test.rb`：全部厂商查询不打开传输，不构造策略；未知能力为 false |
| 纯参数预检 | `tftp_boundary_test.rb#test_vendor_parameter_combinations_are_rejected_before_any_device_io`：逐厂商非法 vrf/source/path 的 opens/writes 均为零 |
| 配置步骤选择和完整提示 | `collection_contract_test.rb`、`running_config_strategy_test.rb`、`collection_prompt_test.rb`：正确业务步骤、缺失/跳过/空清理、提示符假阳性及延迟尾部；失败保留步骤和旧文件 |
| H3C 两类 LLDP 列顺序 | `topology_test.rb`：新旧表头均解析；未知行、部分行、歧义和机箱身份变化拒绝生成或执行计划 |
| PAN-OS 空邻居和候选差异 | `topology_test.rb`：显式空块可忽略，非空缺字段拒绝；`running_config_strategy_test.rb` / `output_sensitive_test.rb`：候选差异阻止采集且不泄漏正文 |
| PAN-OS 引号 | `topology_test.rb`：完整单行备注可读，截断引号和引号内多行均明确拒绝；不输出部分描述 |
| Cisco CDP 身份 | `topology_test.rb`、`operations_reliability_test.rb`：Device ID、接口、邻居和可用 chassis_id 进入证据；未知/缺字段及身份变化拒绝，不偷偷切换 LLDP |
| 山石实际导出文件名 | `connector_test.rb`、`tftp_boundary_test.rb`：采用设备完成行中的名字；非法、缺失及与显式请求不同的目标保持完成事实但报错 |
| Radware 额外交互提示 | `connector_test.rb#test_radware_tftp_uses_native_tgz_prompt`：服务器、tgz 路径、私钥选项和 mansync 应答；`tftp_evidence_test.rb` 拒绝仅应答 echo 或成功字样提示符 |
| TFTP 完成/失败优先 | `tftp_evidence_test.rb`、`operations_reliability_test.rb`：七类成功、echo/未来时态/零字节/部分输出拒绝；真实失败覆盖完成文字，文件名含 error/failed 不误判 |
| 进入/返回视图、读回后保存 | `topology_stages_test.rb`、`support/topology_fixture.rb`：IOS/NX-OS/H3C/山石完整对话，各阶段超时、读回不符/部分解析、保存失败和仅提示符均拒绝；详见 [topology/README.md](topology/README.md) |
| PAN-OS 自动改写 | `topology_stages_test.rb`：缺少候选隔离证据时 I/O 前拒绝，不合成成功 commit；只读功能单独验证 |
| 输出敏感性贯穿收尾 | `output_sensitive_test.rb`、`redaction_contract_test.rb`：完整 Result/备份保留字节，日志/超时/清理/回调错误不含正文；重复登记秘密不破坏跨分片过滤 |
| 真实本地 PTY | `transport_test.rb`、`collection_prompt_test.rb`、安装烟测：分片、分页、延迟、EOF、单响应及累计上限、关闭和 waitpid 回收；子进程仅生成合成回显 |

共享夹具来源和完成语义分别见 [topology](topology/README.md) 与 [tftp](tftp/README.md)。
ConnectorFake 和旧契约测试均保留；没有为覆盖率预加载未测试厂商，也没有新增华为拓扑、
Cisco LLDP、TFTP IPv6 服务器或未经证实的固件命令。测试、夹具和本索引不进入 gem。
