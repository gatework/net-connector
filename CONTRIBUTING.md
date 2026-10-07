# 参与开发

请先阅读 [README](README.md) 和[架构文档](docs/architecture.md)，在源码检出目录中开发。问题和 PR 可使用中文或英文；涉及凭据泄露或可利用漏洞时，使用 [SECURITY.md](SECURITY.md) 中的私密渠道。

## 本地检查

需要 Ruby 3.2 及以上版本、POSIX 环境和 Git。安装依赖后运行完整预检：

```sh
bundle install
script/ci
```

也可使用 `bundle exec rake release:check`；它执行同样的检查，不上传发布包。首次运行需要联网下载依赖、Gitleaks 和 actionlint。检查包含敏感数据扫描、RuboCop、工作流校验、测试、gem 白名单与隔离安装，以及本地 PTY 烟测。它不会连接真实设备。

开发中可直接运行一个测试文件：

```sh
bundle exec ruby -Ilib -Itest test/engine_reliability_test.rb
bundle exec rake lint
```

提交前执行完整的 `bundle exec rake test` 或 `script/ci`。完整测试会检查核心引擎、脱敏与错误处理、批量工作线程各组的行和分支覆盖率，两项均不得低于 80%；任何关键文件没有覆盖率数据也会失败。只运行一个文件不能代替这个门槛，详细口径见[验证文档](docs/VERIFICATION.md)。

## 代码与测试约定

- `engine/` 与 `netdisco/` 启用 `Metrics/MethodLength`（40）和 `Metrics/AbcSize`（60）。超限时按职责拆分，不添加目录豁免或提高阈值来掩盖增长。
- 复用现有 Ruby 对象、不可变档案和厂商策略。复杂的资源所有权、锁、截止时间及脱敏生命周期继续用中文注释说明原因。
- 测试应证明业务行为：失败不覆盖备份、中断释放全部资源、命令不自动重放、错误不泄露凭据。并发测试用队列等同步手段控制执行顺序。
- 使用虚构凭据和 `192.0.2.0/24` 等文档地址。不要提交设备配置、备份、私有地址或日志；扫描规则同样适用于测试和示例。
- 行为或公开契约变更写入 `CHANGELOG.md` 的“未发布”（兼容 `Unreleased`），同步修改相应文档。保留与本次任务无关的工作区改动。

### Ruby 范式与语法边界

- 语法保持 Ruby 3.2 兼容：双引号、两空格缩进、冻结字符串；不强制 80 列或统一尾随逗号，不以 10 行/3 参数为拆分目标。
- 方法按公开入口、protected 扩展点、private 实现组织。步骤提取必须表达独立职责，保留原锁、脱敏、rescue/ensure 和计时范围。
- 命名沿用领域词：`connect`/`close`、`execute_command`/`execute_script`、`running_config`。纯抛错校验统一用 `validate_*!`，不混用 `check_*`；构造用 `build_*`，资源作用域用 `with_*`；不因方法有副作用就追加 `!`。
- 转换用 `map`、筛选用 `select`、副作用用 `each`。`filter_map` 会丢弃 false/nil；`to_h` 的重复键会覆盖；有条件累计用 `each_with_object`。替换前确认内容、顺序和返回值等价。
- 必需键用 `fetch`，允许缺失的嵌套读取才用 `dig`。`&.` 只跳过 nil，不替代 false 或非法类型校验；`||=` 只适用于 nil/false 都等价于未设置的情形。
- 外部输入先校验再转换，不用 `to_i`、`Array()` 等掩盖非法输入。保留缺失、显式 nil、false 的区别及必要哨兵；不扩大配置来源或改变优先级。
- 模式匹配只用于稳定结构，并明确未知结构行为；不批量替换分支。Guard clause 保持返回值及预检顺序。完整透传可用匿名块参数，调整参数时显式传递，保留 `super` 的继承语义。
- Data 用于稳定值对象，Hash 用于配置和外部协议；不为缩短参数列表增加对象。freeze 不会递归冻结，复制规则按对象所有权与现有契约决定。
- 普通失败通过已有错误边界归一化；保留 `cause: nil` 和脱敏先于截断的顺序。资源清理处的 `rescue Exception` 是有理由的例外，清理后保留原中断，Worker 可抑制次级清理异常；不能转换成业务成功。
- 不自动重放设备命令；只有现有连接恢复允许重试。路径锁在会话锁外，完成步骤和持久化回执不能因后续失败丢失。ensure 中不能新增覆盖原异常或返回值的控制流。

RuboCop 启用 Naming 及 GuardClause、SafeNavigation、RedundantSelf、RedundantReturn、ExplicitBlockArgument、HashTransformValues、MapToHash、Next。
同时启用方法间空行与缩进一致性规则。异常变量按角色使用完整名称，关闭强制 `e` 的规则；发布入口 `net-connector.rb` 和 pg 原生接口名称保留明确例外。
自动修正仅使用 `-a` 并逐项审阅，尤其检查块、返回值和校验顺序；不使用 `-A` 或生成排除基线。

保持行为的重构先补缺失的边界测试，再独立搬移方法、调整逻辑、修改名称。
本次迁移与延后项见源码根目录 `RENAMES.md`；通用 Validation、配置 DSL 和参数对象须有真实复用收益，不能仅依据相似语法提取。

## 增加厂商或模板

1. 在 `lib/net/connector/vendor/<厂商>.rb` 声明提示符、命令、交互及策略绑定，并在设备注册入口登记厂商键。已有规则可直接复用，差异逻辑放在该厂商目录中。
2. 只声明实际实现并经过验证的能力。配置采集覆盖登录、分页、完整提示符、失败响应、空配置和视图恢复；TFTP 需要明确的上传完成证据；拓扑变更还需要计划重验与回读。
3. 新 TextFSM 模板放入 `lib/net/connector/templates/`，按需更新 `index`。提供脱敏的正常、空表、畸形与部分输出样本，验证字段和完整性判断；注明样本的设备系列、固件及来源许可。
4. 补齐对应测试及能力矩阵，运行完整预检，确认模板进入实际构建的 gem。现场验证应在 PR 中注明环境和结果，模拟传输测试不能代替现场证据。

PR 请说明具体问题、修改后的行为、验证命令及仍未验证的范围。仓库的 PR 模板和[发布文档](docs/RELEASING.md)提供交付约定。
