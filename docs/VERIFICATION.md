# 验证、依赖与敏感数据

在项目根目录执行：

```sh
bundle install
script/ci
```

`bundle exec rake ci` 和 `bundle exec rake release:check` 使用同一套检查。
`release:check` 可以在仍有 `Unreleased` 变更时运行，不执行发布。

## 检查范围

| 步骤 | 内容 |
| --- | --- |
| `security:check` | 扫描待提交源码和可用的完整 Git 历史；拒绝混入源码的本地凭据、配置和产物 |
| `lint` | 对库、脚本、示例、测试、Gemfile、gemspec 和 Rakefile 执行 RuboCop |
| `lint:workflows` | 用 actionlint 校验 GitHub Actions 工作流 |
| `test` | 执行全部 Minitest，并报告已加载库文件的行与分支覆盖率；敏感信息和发布测试使用临时文件、临时仓库与模拟远端响应 |
| `package:verify` | 构建 gem，检查元数据、文件白名单、源文件字节和执行位，扫描解包内容及元数据，再进行隔离安装 |

隔离安装清除当前 Bundler 和 Ruby 注入变量，分别验证普通 `gem install`
和只有 `net-connector` 依赖的最小 Bundler 应用。烟测加载全部厂商，使用本地
PTY 子进程采集配置，读取包内 TextFSM 模板，并检查 CLI。它不连接网络设备，
也不证明现场设备协议或真实发布服务已验收。
覆盖率目前只用于观察，不设硬性门槛；未加载文件会单独计数。

CI 矩阵为 Ubuntu 24.04 / macOS 15 × Ruby 3.2、3.3、3.4、4.0。
GitHub Actions 固定提交 SHA；Gitleaks 与 actionlint 固定版本和各平台归档
SHA-256，首次使用时从官方 GitHub Release 下载，缓存到 `tmp/tools/`。
已有工具归档和可执行文件也会再次校验。初次安装依赖和下载工具需要联网；
隔离安装复用本次 Bundler 安装所得的 gem 缓存。Bundler 自身优先使用缓存
安装；若它是 Ruby 随附且没有缓存的默认 gem，则直接加载该精确版本。

## 依赖与打包

运行依赖写在 `net-connector.gemspec`，包括直接使用的、可能从 Ruby 默认
安装中拆出的标准库 gem。开发工具只写在 Gemfile，不进入运行依赖。
`expect-pty` 使用 `~> 0.3.1`；开发用 `parallel` 保持 1.x，以支持 Ruby 3.2。

本项目是库，`Gemfile.lock` 仅作本地开发记录并被忽略；各 Ruby 版本的 CI
分别解析兼容依赖。应用使用者应在自己的应用中提交 lockfile。测试和打包
脚本通过隔离安装检查运行依赖，避免依赖开发环境里偶然存在的 gem。

gem 只收录库代码、TextFSM 模板、CLI、架构/验证/发布文档、README、LICENSE 和
CHANGELOG。测试、示例、发布工具、工作流、本地评审快照、配置和备份不进入包。
更改 gemspec 后，实际归档仍须通过独立的文件白名单检查。

## 敏感数据

Gitleaks 默认规则之外，还检查网络设备密码/SNMP community 配置、环境变量
中的字面量凭据和私有 IPv4 地址。公开示例使用 `replace-me`、环境变量引用和
文档地址（例如 `192.0.2.1`）。代码和测试不享受目录级豁免；内联
`gitleaks:allow` 或 `.gitleaksignore` 也不能绕过这里的扫描。

有 Git 仓库时，源码检查覆盖已跟踪文件和未忽略的新文件，并以 `--all`
检查本地可用引用的历史。CI 使用 `fetch-depth: 0`，浅克隆会被拒绝。
没有 Git 元数据或没有提交时，只执行源码检查并明确报告历史检查不可用；
临时测试仓库中已删除敏感数据的提交也必须能被历史扫描检出。

扫描失败会停止后续构建或发布。日志和 `tmp/security/*.json` 报告仅记录规则、
文件与行号，不记录匹配文本或秘密值；报告权限为 `0600`。最终 gem 和
`--artifact` 重试同样接受检查。扫描器异常、缺失报告也按失败处理。

`.gitignore` 排除本地环境文件、配置、凭据、SSH 密钥、设备备份、日志、报告、
构建包、依赖缓存与编辑器文件；保留 `.env.example`、厂商代码与工作流。
忽略规则不会移除已经跟踪的文件，源码检查会拒绝已跟踪的禁入路径。
已有 Git 暂存区仍需包含最终脱敏后的修改，避免提交旧的暂存内容。

发现真实敏感数据时，在源码或示例中替换为占位值，并检查历史及已分发的包。
若凭据已经泄露，需在对应系统撤销或轮换；仅修改示例不能使旧凭据失效。
扫描工具不会自动改写 Git 历史或真实设备备份。规则用于拦截常见泄露，
发布前仍需人工确认设备名称、拓扑和业务配置等上下文信息是否适合公开。
