# net-connector

网络设备交互模块：以面向对象的方式抽象异构多厂商、多型号设备的登录、命令执行、配置读取、保存/提交、检查点与配置导出。它是 netops 的设备端口实现，fabric、wireless、firemon 等工具经它与设备对话。

```
工具（fabric / wireless / firemon）── 组装 ──▶ netops ops（采集、变更、备份……）
                                                 │ ops.Dialer / ops.Session
net-connector ─────────────────── 实现 ──────────┘
  connector  会话门面：登录、Collect/Write/Save/Commit/Export/Checkpoint
  vendors    12 个内建平台 + 注册表（清单识别顺序）
  driver     平台契约与可选能力接口
  terminal   CLI 对话引擎：Grammar 数据 + 唯一解释器
  transport  ssh（x/crypto/ssh）、telnet
```

## 用法

```go
ssh, err := sshtransport.New(sshtransport.Options{KnownHosts: "~/.config/tool/known_hosts", HostKeys: sshtransport.AcceptNew})
if err != nil { return err }
d, err := connector.NewDialer(connector.Options{
    Registry:    vendors.Builtin(),
    Credentials: credential.Env{Environ: env},
    Transport:   transport.Retrying{Dialer: ssh, Retries: 1},
})
if err != nil { return err }

// 交给 netops 用例
report, err := ops.Collect(ctx, ops.CollectRequest{Dialer: d.Port(), ...})

// 或直接使用会话
opErr, closeErr := d.Open(ctx, dev, func(ctx context.Context, s *connector.Session) error {
    cfg, err := s.Config(ctx)
    ...
    return s.Save(ctx)
})
```

`vendors.Builtin()` 同时实现 netops `inventory.Classifier`，可直接注入 `inventory.Netdisco` 做平台识别。

## 内建平台

| 平台键 | 类型 | 能力 |
|---|---|---|
| `h3c_wireless` / `h3c` | `h3c.Wireless` / `h3c.Switch` | config、save、export(TFTP)、readonly |
| `cisco_nxos` | `cisco.NXOS` | config、save、export、checkpoint、readonly |
| `cisco_ios` | `cisco.IOS` | config、save、export、readonly（enable 提权） |
| `huawei` | `huawei.VRP` | config、save、export、readonly |
| `juniper` | `juniper.Junos` | config、commit（exclusive、check、confirmed） |
| `palo_alto` | `paloalto.PANOS` | config（set 格式，前后 `show config diff` 为空才接受）、commit、HA 角色 |
| `hillstone` | `hillstone.StoneOS` | config、save、HA 角色 |
| `fortinet` | `fortinet.FortiOS` | config |
| `radware` | `radware.Alteon` | config、HA 角色 |
| `centec` / `topsec` | `centec.CNOS` / `topsec.TOS` | config（centec 另有 save） |

能力矩阵由 `driver.Capabilities` 生成并在 `vendors` 测试中固定。所有对话证据来自脚本化设备（`connectortest`），未经实机验证。

## 依赖

go-expect（流匹配）、netops（领域模型与端口）、golang.org/x/crypto/ssh、skeema/knownhosts、golang.org/x/text + saintfish/chardet（编码）、charmbracelet/x/ansi（控制序列）。测试使用 gliderlabs/ssh 与 goleak。
