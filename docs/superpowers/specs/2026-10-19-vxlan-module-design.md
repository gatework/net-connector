# VXLAN 对接方案修订说明

旧方案撤回：不把 VXLAN 采集、解析、报告或业务 CLI 迁入 net-connector，不新增 Net::Connector::Vxlan、net-vxlan 或重复的业务门面。

用户明确：连接器负责设备登录和脚本执行；vxlan 集成领域业务；拒绝重复样板，模块专注、简单、容易集成。

替代设计位于相邻 vxlan 仓库：docs/superpowers/specs/2026-10-19-connector-integration-design.md。实施以替代设计为准，本文件仅避免旧方案被误用。尚未修改产品代码。
