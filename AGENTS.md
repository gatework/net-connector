# net-connector 开发说明

遵循 [gatework Go 工程规范（go-standards/STANDARD.md）](https://github.com/gatework/go-standards/blob/v1.2.0/STANDARD.md)；提交前运行 `make check`。

net-connector 是设备交互模块：传输、CLI 对话、多厂商驱动，并实现 netops 的 `ops.Dialer`/`ops.Session` 端口。设计见 [docs/design.md](docs/design.md)，重写决策见 [docs/adr/0001-rewrite.md](docs/adr/0001-rewrite.md)，术语见 [GLOSSARY.md](GLOSSARY.md)。旧实现保留在 `../net-connector-legacy`，只作行为与证据参考，不复制代码。

## 边界

- 分层自下而上：`transport` → `terminal` → `driver` → `vendors` → `connector`，由 `architecture.yaml` 强制。新增包先登记。
- 只做设备交互。备份归档、拓扑/描述修正、批量调度、清单、配置文件等业务与通用能力属于 netops 或各工具，不进入本模块。
- 厂商差异只以数据表达：`terminal.Grammar`（提示符、错误回显、自动应答、分页、异步日志）与 `terminal.Procedure`（保存、提交、检查点、传输及其正向证据）。厂商包不写 expect 循环，不出现 `if vendor == ...` 分支。
- 能力是可选接口（`driver.Saver`、`Committer`、`Checkpointer`、`Exporter`……），只有对话证据（`connector` 中的逐字节对话测试）存在时才声明。

## 不可破坏的语义

- 每个凭据每次登录最多发送一次；第二次出现密码提示即认证失败（`auth_failed`），锁定单独报告（`locked`），均不重试。只有认证前的连接失败可重试。
- 未登记的问题（`[Y/N]`、`[confirm]` 等）一律中止（`interaction`），不猜测；`RiskDisruptive` 规则只在命令显式 `Allow` 时应答。
- 保存、提交、检查点、传输只以正向签名为成功；回到提示符不算证据（`unconfirmed`）。失败签名按行锚定，避免把提示性文字误判为失败。
- 写入一旦发出不重放；HA 备机（`LoginState.Writable=false`）在发送前拒绝写入。
- 错误只携带 netops `failure.Code` 与稳定 `Reason`，不含设备回显或凭据；凭据只以 `secret.Secret` 传递并在会话中注册脱敏。
- 主机密钥 `replace` 策略必须显式指定专用 known_hosts。

## 构建与检查

依赖使用已发布的 netops v0.1.0。提交前运行 `make check`，以 `GOWORK=off` 验证固定依赖。发布、打 tag 需明确授权。

```sh
go test -race ./...
make fuzz
```

逐字节对话测试只证明会话逻辑，不代表真实设备兼容；新增厂商能力应附带实机或实验室证据说明。
