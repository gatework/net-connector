# TFTP 合成夹具

`test/support/tftp_fixture.rb` 的七类成功对话直接提取自仓库原有
`test/tftp_evidence_test.rb` 的 CASES，没有新增设备命令或放宽完成匹配规则。
本轮基线为 `3192377190fa8b28334e1f39007789ef2ae5cc6e` 上的原有工作树；
原始文件和差异已在 NC-00 保存。本轮提取日期为 2026-09-27。

| 厂商 | 继承的合成证据 | 回执来源声明 |
| --- | --- | --- |
| IOS | 正整数 bytes copied | copy running-config，running/cfg |
| NX-OS | Copy complete | copy running-config，running/cfg |
| H3C | Transfer complete | 显式文件 saved_file/unknown；display startup 探测后 startup/unknown |
| 华为 | Transfer completed successfully | 指定文件 saved_file/unknown |
| 山石 | Export ok 且含目标名 | export configuration startup，startup/dat；实际名取设备完成行 |
| PAN-OS | Sent 正整数字节 | from running-config.xml，running/xml；固定名碰撞仍拒绝 |
| Radware | Current config successfully tftp'd | 原生导出 native_archive/tgz，不推断完整运行配置 |

这些样本的真实型号、固件、现场采集日期和外部会话来源均为 **unknown**，
只证明已有解析契约；未宣称任何新型号或固件通过现场验证。地址、用户名、
文件名和诊断秘密均为合成值，没有真实配置、凭据或服务器内容。

`tftp_evidence_test.rb` 保留命令/交互 echo、含成功字样的文件名、提示符、
未来时态、不完整/零字节进度、失败优先和终端控制符测试。
`tftp_boundary_test.rb` 增加源探测间隙竞争、无 I/O 参数预检、来源/格式、
实际目标不符和完成后失败；只使用 ConnectorFake，不打开设备网络连接。
隔离安装烟测另使用本地 PTY 子进程生成相同 IOS 完成行，不执行真实上传。

所有成功回执仍为 device_reported，服务器文件、摘要、时间/版本关联未核验。
现有 PAN-OS 同批碰撞规则不能推导跨批次或跨进程隔离；没有采用串行覆盖来扩大可执行集合。
