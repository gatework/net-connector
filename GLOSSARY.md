# 术语

| 术语 | 含义 |
|---|---|
| 平台（Platform） | 规范平台键，如 `h3c`、`cisco_nxos`，与 netops `device.Device.Platform` 共用词汇。 |
| 驱动（Driver） | 一个平台对象：平台键 + Grammar，外加按证据声明的可选能力。 |
| 方言（Grammar） | 设备 CLI 的声明式描述：登录对话、各模式提示符、提权、分页、错误/告警签名、异步日志、问题形状与应答规则。 |
| 签名（Signature） | 一条可识别的设备话语及其稳定原因（Reason），如 `invalid_input`、`save_ok`。 |
| 规则（Rule） | 对某个问题的自动应答，带风险等级（routine / disruptive）与次数上限。 |
| 规程（Procedure） | 需要正向证据的长操作：保存、提交、检查点、回滚、导出。 |
| 回执（Receipt） | 规程成功的证据：匹配的签名与捕获值（字节数、作业号）。 |
| 模式（Mode） | 提示符所示的 CLI 模式：user、privileged、config、config_sub。 |
| 固定提示符 | 登录后学到主机名并将提示符正则固定到该主机名，避免输出中的 `#`、`>` 被误认。 |
| 登录状态（LoginState） | 登录后得知的设备状态，如 HA 角色及是否可写。 |
