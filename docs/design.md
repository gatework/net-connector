# net-connector 设计

## 目标

以网络管理员的视角，把"与一台设备对话"这件事建模成数据 + 唯一引擎：厂商只描述它的 CLI 长什么样、哪些话意味着什么，会话引擎负责登录、执行、应答、判定。业务流程（采集、变更、备份、拓扑修正）全部在 netops 与工具中，经 `ops.Dialer`/`ops.Session` 端口使用本模块。

## 分层

| 包 | 职责 | 依赖 |
|---|---|---|
| `transport` | 打开到设备的字节流；SSH（x/crypto/ssh、knownhosts、跳板机、旧算法显式开启）、Telnet（最小 RFC 854 协商）；认证前连接失败线性退避重试 | netops `failure`、`secret`、`store/disk` |
| `terminal` | Grammar/Rule/Signature/Procedure 数据模型；Session 引擎：登录、提权、模式切换、命令执行、规程判定、渲染与解码 | expect、netops `failure`、`secret` |
| `driver` | `Driver`（平台键 + Grammar）与可选能力接口；`Base` 嵌入；`Registry`（有序、实现 netops `inventory.Classifier`）；`Override` 站点定制 | `terminal` |
| `vendors/*` | 各厂商家族：方言组装、规程构造、HA 角色解析、清单识别 | `driver`、`terminal`、`vendors/internal/family` |
| `connector` | 组合根之外的门面：凭据、传输、登录、能力调度；`Session` 实现 `ops.Session` | 以上全部（除具体厂商与传输实现） |

## 交互模型

一次会话分 7 个阶段，每个阶段是"签名集合 + 处置策略"：

1. 连接：拒绝/不可达/超时可重试；主机密钥按策略（strict / accept-new / replace）。
2. 登录前：横幅、"Press RETURN"、免责声明按 `Login.Banner` 规则应答。
3. 认证：带内用户名/密码提示各应答一次；失败、锁定、密码过期（拒绝修改）分别识别。
4. 提示符与模式：各模式提示符正则以 `{host}` 占位；登录后固定主机名；`role`、`pending` 命名组承载 HA 与未提交标记；提权（enable）密码只发一次。
5. 会话准备：关闭分页、加宽终端；失败即会话失败。
6. 命令执行：分页兜底（文本不入响应）、错误回显（拒绝，保留会话）、告警与异步日志（入 Notices）、已登记问题按风险应答、未登记问题中止（发送 Ctrl-C 并重新同步提示符）、长时间静默按 `Idle` 判为停滞。
7. 长操作：`Procedure` 先查失败签名再要求成功签名，命名组进入回执。

## 会话录像

每个会话由 expect 引擎录像（默认开启，`~/.local/expect/<日期>/<设备标签>_<时间>_<会话>.{log,cast}`），`connector.Options.Recorder` 或 `EXPECT_RECORD_*` 环境变量配置，`record.Disabled()`/`EXPECT_RECORD=off` 关闭。凭据与 `Grammar.Redact` 匹配的配置密文在录像中遮蔽；`Response` 仍为原文。测试必须显式关闭录像。

## 安全不变量

见 [AGENTS.md](../AGENTS.md)。所有阶段的错误都是 netops `failure.Error`，`Reason` 为稳定签名名，不含设备原文。

## 证据层次

- `connectortest`：脚本化设备逐字节校验会话发送的每一个字节（包括"没有发送第二次密码""没有回答 y"）。
- `transport/ssh` 测试使用进程内 gliderlabs/ssh 服务验证认证、主机密钥策略、跳板机。
- 以上都不是实机证据；平台能力仅在有对话证据时声明，实机验证需在实验室补充。

## 尚未覆盖

- Comware 归档回滚、VRP 两阶段提交（`commit`）、FortiOS 保存语义：缺少对话证据，暂不声明。
- 事实（型号/序列号/版本）解析在 netops `facts`；本模块只负责执行其只读命令（`Session.Collect`）。
- netman CLI 与 tftp-archive 服务端核验待后续轮次在 netops 之上重建。
