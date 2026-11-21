# 变更记录

## v0.10.1（2026-11-20）

- 流引擎由 go-expect 换为 `github.com/gatework/expect`；每个会话默认录像（`connector.Options.Recorder`、`terminal.Options.Recorder/Label`，`EXPECT_RECORD_*`）。
- `terminal.Grammar.Redact` 可遮蔽录像中的配置密文。有捕获组时遮蔽子匹配，否则遮蔽整个匹配。脱敏规则在读取设备输出前生效。

## v0.10.0（2026-11-20）

以 netops 为内核的重写，破坏性变更，见 [ADR 0001](docs/adr/0001-rewrite.md)。

- 新分层：`transport`（x/crypto/ssh、telnet）、`terminal`（Grammar + 单一对话引擎）、`driver`（契约与可选能力）、`vendors`（12 个平台）、`connector`（实现 netops 端口）、`connectortest`（逐字节脚本设备）。
- 交互模型：凭据单次发送、锁定识别、未知问题中止、破坏性问题需显式允许、规程正向证据、HA 备机拒写、GB18030/Big5 解码。
- 移除：netman、tftp-archive、fleet、topology、transfer、facts、inventory、netdisco、storage、config、parallel、textfsm、archive；相应能力迁往 netops 或后续轮次。
