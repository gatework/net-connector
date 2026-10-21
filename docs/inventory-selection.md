# 共享设备筛选

`Net::Connector::Inventory::Selection` 是备份、拓扑、VXLAN 和 Wireless 共同使用的筛选实现。它只处理已有清单，不访问 Netdisco、读取凭据或连接设备。

```ruby
require "net/connector/inventory/selection"

selection = Net::Connector::Inventory::Selection.new(
  include_hosts: ["192.0.2.0/24", "2001:db8::/32"],
  exclude_hosts: ["192.0.2.1-9"],
  include_names: ["edge"], exclude_names: ["spare"],
  include_vendors: [:cisco_nxos],
  include_models: ["N9K-*"], model_match: :glob
)
decision = selection.evaluate(host: "192.0.2.10", name: "edge-1",
  vendor: :cisco_nxos, model: "N9K-C93180")
decision.selected? # true
decision.reasons   # []；拒绝时给出稳定原因代码，不包含设备正文
```

同字段包含为 OR，跨字段为 AND，排除优先。名称和型号不区分大小写，匹配模式为 contains、prefix、glob；空模式和非法地址规则在构造时拒绝。缺失型号不匹配任何包含模式，包括 glob `*`。未配置包含条件表示该字段不限制。

vendor 指连接器平台标识，不是 Netdisco 原始厂商标签；Netdisco Rules 先完成识别，再交给 Selection。设备合法性、平台是否支持当前操作、凭据是否满足属于独立预检，不能用“筛选通过”代替这些判断。

`Inventory::AddressSet` 维护精确地址和合并区间，不展开网段。旧 Netdisco::AddressSet 已删除。`Inventory::Filters` 为全部脚本声明相同的 --hosts、--exclude-hosts、--name、--exclude-name、--vendor、--exclude-vendor、--model、--exclude-model、--name-match、--model-match；Netdisco 单台 --host 仍属于明确目标选择，需要验证目标存在。

备份/拓扑的 YAML：

```yaml
inventory:
  include_hosts: [192.0.2.0/24]
  exclude_hosts: []
  include_names: [edge]
  exclude_names: [spare]
  include_vendors: [cisco_nxos]
  include_models: ['N9K-*']
  exclude_models: []
  name_match: contains
  model_match: glob
```

对应环境变量新增 `NC_INCLUDE_MODELS`、`NC_EXCLUDE_MODELS`、`NC_MODEL_MATCH`。CLI 参数高于配置；规则构造后与调用方可变数组分离。静态领域脚本使用同一匹配器，配置发现与合并仍由宿主负责。

核心解析、离线 review 和全局帮助无需连接器。VXLAN/Wireless 的 collect（包括 collect --help）从本组件读取统一参数，须安装含此能力的当前连接器候选包；不会加载整个网络引擎。此次实现未发布远程版本。
