# 拓扑分阶段合成夹具

`test/support/topology_fixture.rb` 使用 ConnectorFake，记录进入视图、修改、返回执行视图、
运行配置读回和保存的顺序。所有设备标识均为合成值，型号、实际固件版本和现场采集日期为
**unknown**。2026-09-27 构造；没有读取真实设备、配置或凭据。

保存命令沿用仓库已有档案，不增加任何设备锁、commit job 或回滚命令。完成行只表示
设备报告保存完成，不代表存储介质断电实验，也不证明其他管理员没有并发改动。

| 厂商 | 文档证据和夹具边界 |
| --- | --- |
| Cisco IOS | [IOS CLI 保存示例](https://www.cisco.com/c/dam/en/us/td/docs/ios/dial/configuration/guide/12_4t/dia_12_4t_book.pdf) 给出 `[OK]`；测试含配置视图及返回视图，实际固件 unknown |
| Cisco NX-OS | [Cisco 官方操作示例](https://www.cisco.com/c/en/us/support/docs/csa/cisco-sa-20200205-nxos-cdp-rce.html) 给出最终 `Copy complete.`；进度 100% 或仍在保存的行不单独确认完成 |
| H3C | [配置文件管理命令](https://www.h3c.com/en/d_202410/2284467_294551_0.htm) 的 save force 示例提供主板保存完成行；测试不是型号兼容认证 |
| Hillstone | [StoneOS CLI 5.5R5](https://kb.hillstonenet.com/en/wp-content/uploads/2017/11/StoneOS_CLI_User_Guide_Complete_Book_5.5R5-1.pdf) 配置管理章节说明 save 的语义，第 384 页在重启前保存示例中给出 `Saving configuration is finished`。将该行用于已有 save all 响应的匹配是保守推断，save all 的现场输出尚未核验；其他输出返回未确认 |
| PAN-OS | [提交模型](https://docs.paloaltonetworks.com/ngfw/pan-os-cli-quick-start/use-the-cli/commit-configuration-changes) 与[锁的区别](https://docs.paloaltonetworks.com/ngfw/administration/firewall-administration/launch-the-web-interface/manage-locks-for-restricting-configuration-changes)说明候选配置及并发边界；没有目标固件锁/提交实验，自动改写入口拒绝执行，只读解析继续测试 |

故障样本包括各阶段超时、读回不匹配、额外的未识别接口行、保存进度未结束、
提示符但无完成行，以及失败与完成文字同时出现。成功、失败、部分输出和视图转换
均由测试断言；这些是协议回归证据，不是对所有型号或固件的通过声明。
