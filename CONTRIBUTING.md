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
- 行为或公开契约变更写入 `CHANGELOG.md` 的 `Unreleased`，同步修改相应文档。保留与本次任务无关的工作区改动。

## 增加厂商或模板

1. 在 `lib/net/connector/vendor/<厂商>.rb` 声明提示符、命令、交互及策略绑定，并在设备注册入口登记厂商键。已有规则可直接复用，差异逻辑放在该厂商目录中。
2. 只声明实际实现并经过验证的能力。配置采集覆盖登录、分页、完整提示符、失败响应、空配置和视图恢复；TFTP 需要明确的上传完成证据；拓扑变更还需要计划重验与回读。
3. 新 TextFSM 模板放入 `lib/net/connector/templates/`，按需更新 `index`。提供脱敏的正常、空表、畸形与部分输出样本，验证字段和完整性判断；注明样本的设备系列、固件及来源许可。
4. 补齐对应测试及能力矩阵，运行完整预检，确认模板进入实际构建的 gem。现场验证应在 PR 中注明环境和结果，模拟传输测试不能代替现场证据。

PR 请说明具体问题、修改后的行为、验证命令及仍未验证的范围。仓库的 PR 模板和[发布文档](docs/RELEASING.md)提供交付约定。
