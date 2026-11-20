# ADR 0001：以 netops 为内核重写 net-connector

日期：2026-11-19　状态：已采纳

## 背景

v0.9.x 的 net-connector（约 8.4 万行）把设备交互、业务流程（备份、拓扑、传输、事实采集、批次报告）与通用设施（配置、存储、清单、Netdisco、并发池、CLI、tftp-archive）放在一个模块。netops 又反向依赖它（`connect`、`batch→parallel`、`inventory→netdisco/fleet/platform`、`store→storage`、`bootstrap→config`），内核与适配器互相耦合。

## 决策

1. 依赖方向改为 netops ← net-connector：netops 是纯内核，不导入 net-connector 与 go-expect；net-connector 实现 `ops.Dialer`/`ops.Session`，取代 `netops/connect`。
2. net-connector 只做设备交互；LLDP/CDP 邻居（`netops/neighbor`）、接口名规范化（`netops/iface`）、描述审计与变更（`netops/describe`）、Netdisco 清单、私有文件存储下沉 netops。
3. SSH 改用 `golang.org/x/crypto/ssh` 与 `skeema/knownhosts`，跳板机进程内串接，不再驱动系统 ssh 与 PTY；Telnet 无主流库，保留最小协商实现。
4. 设备差异以数据建模（`terminal.Grammar`、`terminal.Procedure`），由唯一引擎解释；能力为可选接口。
5. netman CLI 与 tftp-archive 移出（后续轮次基于 netops 重建）。旧仓库更名为 `net-connector-legacy` 仅作参考；新模块沿用路径，版本 v0.10.0（破坏性）。

## 后果

- 消费者改为在组合根组装 `connector.Dialer`，并把 `vendors.Builtin()` 作为清单 `Classifier` 注入。
- 旧 API（`connector.Device`、`Operation`、租约、`platform.Registry`、`fleet`、`transfer`、`topology`）不再提供。
- 去掉对系统 ssh 的依赖后，`~/.ssh/config` 中的 ProxyCommand 等不再生效，跳板机经 `ssh.Options.Jump` 配置。
- 旧实现中的 H3C 规则号替换（防火墙策略）属于 firemon 业务，未迁入。
