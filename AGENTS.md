# net-connector 开发指南

适用于本仓库。当前工作区为 net-connector-trunk；相邻 net-connector、net-connector-optimization 和 trunk 副本可能有不同内容，修改前核对 Git 根目录与状态，不自动合并其他副本。

## 职责与契约

- Device/Profile 声明厂商能力与命令，Session 管理设备对话和连接状态，Execution 管理脚本步骤与累计预算，ResponseReader 管理有界响应，Transports 接管底层 PTY。
- expect-pty 负责字节匹配、IO 与进程；连接器负责认证、提示符、设备业务和日志上下文。不要把厂商语法放入 PTY 通用层。
- 发送前校验整批脚本。设备已执行的步骤必须保留；日志、回调、保存失败不能抹去完成事实或导致自动命令重放。
- 读取、分页及动态响应共用截止时间；错误区分命令失败、断链、同步未知、输出超限和取消。原始响应与终端渲染的业务正文分开。
- 输入字符串和集合按边界建立快照，不冻结调用方对象。编码校验、来源证据和深度不可变分别验证。
- 脱敏词表与输出敏感范围属于当前操作。临时秘密不能泄露到错误、inspect、日志或后续会话；过滤字节由 expect-pty 的 Redactor 承担。
- 存储和归档明确“设备完成、文件落盘、持久性确认”的区别；原子替换与文件锁各有职责，不能以文件存在证明操作成功。
- 保持厂商命令解析器的文件/类型映射；通用辅助对象按能力命名，不机械拆分类或添加无契约的包装层。

## 修改与验证

- 以 gemspec、锁文件和 CI 为依据，当前测试矩阵为 Ruby 3.4/4.0；使用项目 Ruby、Bundler 和中文注释。
- 保留暂存、未暂存和未跟踪工作，不 reset/clean/stash。修改不自动包含提交、推送或发布。
- 根目录运行 `bash script/ci`，包括秘密扫描、lint、工作流检查、完整测试、覆盖率比较、基准 smoke、构建及普通/Bundler 隔离安装。macOS 环境必要时使用 `zsh -ic 'bash script/ci'`。
- 定向测试使用 `bundle exec ruby -Itest test/<name>_test.rb`；数据库查询改动另跑 `bundle exec rake test:postgres`，仅使用脚本创建的临时数据库。
- expect 候选源码联调：`RUBYLIB=../expect-ruby/lib bundle exec rake test`；同时保留锁定依赖测试。隔离包验证还须确认实际安装的 expect 候选字节，不能仅凭版本号相同判定。
- `script/benchmark_memory.rb` 提供完整离线场景；`script/benchmark_dialogue.rb` 支持 `--library` 基线对比。正确性断言在计时外，记录规模与分配量，不把微基准外推成网络收益。
- 示例入口修改后，从实际 checkout 直接运行其普通命令，不只通过额外 `-Ilib` 或旁边工作树验证。
- 更新 CHANGELOG 与相关文档；远程发布与仓库可见性变更仅按明确授权执行。

## 清单选择

`Inventory::Selection` 是地址、名称、连接器厂商、型号过滤的唯一实现；`Inventory::Filters` 维护共享 CLI 参数，`Inventory::AddressSet` 维护地址区间。Netdisco Rules 只保留厂商解析/映射并组合 Selection。其他脚本直接复用，禁止复制筛选循环或恢复 Netdisco::AddressSet 旧入口。筛选不得访问凭据或建立连接。
