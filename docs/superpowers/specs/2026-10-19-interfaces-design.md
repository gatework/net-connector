# 接口集合对象设计

用户要求将平铺的接口描述动作改为面向对象的 API，并明确选择 `device.interfaces.plan / audit / apply / sync`。本次在现有未发布工作区上增量实现，保留其他在途工作。

## 对外契约

- 单设备通过 `device.interfaces` 获取绑定该设备的 `Net::Connector::Interfaces` 对象；获取对象不连接、不读取设备。同一设备复用该对象，它不缓存现场邻居、描述或计划，不拥有独立连接和关闭流程。
- `neighbors` 返回邻居数组；`descriptions` 返回接口到当前描述的 Hash。
- `plan(abbreviate: true, lowercase: false, &formatter)` 返回不可变的 `Interfaces::Plan`，只读、不执行变更。
- `audit(abbreviate: true, lowercase: false, description_matcher: nil, &formatter)` 返回 `Interfaces::Audit`，保留逐接口不确定证据。
- `apply(plan, confirmed: false)` 返回原有 `Result`；显式确认、目标一致、命令一致和现场证据重验通过后才能变更，按修改、读回、保存顺序执行。
- `sync(abbreviate: true, lowercase: false, &formatter)` 表达直接同步意图，在同一设备会话内规划和应用；无变化不修改、不保存。
- `plan`、`audit`、`sync` 使用同一格式参数校验，非法布尔值在任何设备 I/O 前拒绝。`plan` 的全部采集也由 `with_operation(:plan)` 保护，确保其他线程/Fiber 无法插入设备操作；sync 在自己的租约中复用私有计划构造流程，不嵌套申请租约。

## 实现结构

直接将 `device/topology.rb` 的业务协调对象和配套文件迁移为 `device/interfaces.rb` 与 `device/interfaces/`，不增加只转发旧动作的门面。原 `Topology::Plan/Audit/Change/Neighbor` 等类型归入 `Interfaces`；值对象、厂商策略、执行阶段的职责与数据格式不变。

设备能力只公开 `interfaces`。原设备平铺动作和 `interface_descriptions`、`neighbors` 入口、原 `Net::Connector::Topology` 常量与加载路径移除，遵循当前未发布迁移不保留别名的约定。`supports?(:neighbors / :interface_descriptions / :interface_description_changes)` 能力键继续表明实际功能。

厂商的 `topology_strategy` 档案字段和厂商 `Topology` 策略名称继续描述邻居拓扑规则；它们的公共基类改用 `Interfaces::Strategy`。Netdisco CLI 的 Topology 命令/报告目录仍表示整个拓扑工作流。

Netdisco Fleet/Operation 的既有多设备 API `plan_descriptions`、`apply_descriptions`、`sync_descriptions` 保留显式批次语义和 `Operation::Batch` 返回值；内部所有单设备访问统一改为 `connector.interfaces.*`。这次用户选择的是单设备接口集合，不额外添加 Fleet 审计能力、单端口筛选或新的批次资源框架。

## 不变量与交付

- Ruby >= 3.2；不新增依赖；解释性源码注释使用中文，遵循 CONTRIBUTING。
- 设备对象继续持有唯一会话，接口对象不创建会话、线程、连接池或独立关闭入口。
- 不缓存现场事实；同一对象重复规划必须重新读取，陈旧计划仍在写入前失败。
- 无确认、错误目标、修改命令、未知证据及能力不足不发生配置写入；不自动重放设备命令。
- 已执行步骤、读回/保存边界、关闭和中断语义继续由原实现承担。
- 迁移真实调用方、测试、双语使用文档、架构文档、RENAMES 和未发布变更记录。历史基准产物保留原始内容。
- 验证以现有合成设备传输和本地 PTY 为限，不连接真实网络设备；不修改 expect-pty，不提交或发布当前混合工作区。
- 本次改动前基线为 lint 285 files、测试 1133 runs / 12025 assertions 全通过；另有一次 expect-pty 间歇短命令测试失败未定位，不能宣称底层连接全矩阵稳定。
