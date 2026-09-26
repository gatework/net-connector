# 发布

发布脚本参考 `expect` 项目的同一产物验证流程。本地复用已有 `gem` / `gh`
登录；GitHub Actions 使用自己的令牌。发布前先执行：

```sh
bundle install
bundle exec rake release:check
```

此命令不会上传，详细检查范围见 [VERIFICATION.md](VERIFICATION.md)。

## 准备版本

1. 在 `lib/net/connector/version.rb` 设置新的稳定 `X.Y.Z` 版本。
2. 将 CHANGELOG 的 `Unreleased` 内容移入对应的 `## X.Y.Z` 或
   `## X.Y.Z - YYYY-MM-DD` 段；版本说明不能为空。
3. 提交最终源码，确认工作区干净，并将提交推送到目标 GitHub 仓库的 `main`。
4. 执行 dry run，保留生成的 gem 和 SHA-256，审核后选择下面一种发布方式。

```sh
ruby script/release.rb --dry-run
```

dry run 执行本地检查，创建独占的 `tmp/release/<version>/candidate-*/` 目录，
保存经过验证的 gem、`SHA256SUMS` 和发布说明，不访问发布 API 或上传文件。
它允许未提交的工作区用于预检，但仍要求版本与发布说明已经整理完成。
正式发布额外要求干净且未变化的 Git 提交。

当前存在尚未归档的 `Unreleased` 时，发布脚本（包括 dry run）会拒绝继续；
需要先整理版本。日常使用 `release:check` 不受此限制。

## 本地发布

```sh
ruby script/release.rb
```

默认从 `GITHUB_REPOSITORY` 或 GitHub `origin` 推导仓库；也可用
`--repository OWNER/REPO` 指定。脚本检查目标 `main` 包含本次提交，已有同名
标签必须指向同一提交；随后创建或复用 GitHub Release，再上传 RubyGems。
首次发布可以由脚本创建版本标签。

如果已经审核过某个包，使用其真实路径替换下例占位路径：

```sh
ruby script/release.rb --artifact /path/to/verified/net-connector-X.Y.Z.gem
```

此模式不重新构建，仍扫描源码与历史，验证包的版本、元数据、文件字节、执行位
及敏感信息，然后复制到本次独占目录。也支持与 `--dry-run` 组合。
`--rubygems-only` 只发布 RubyGems，仍检查本地提交和产物，不需要 GitHub 登录。

本地发布使用已有的 `gem` 登录和 `gh` 登录。请在终端配置凭据，避免把凭据
写进参数、源码或发布文档。脚本不修改本地认证配置。

## GitHub Actions 发布

仓库中配置 `RUBYGEMS_API_KEY` Actions Secret，并赋予发布此 gem 所需的权限。
Runner 不继承本机 RubyGems 登录。GitHub 操作使用工作流自带的 token。

提交和推送版本修改后，创建并推送对应的 `vX.Y.Z` 标签，在该标签上手动运行
`Release` 工作流。只允许标签与 gem 版本一致且说明已归档的发布。
工作流先复用完整 CI 矩阵，全部通过后下载 Ubuntu / Ruby 4.0 验证的同一个
gem，再执行 `--artifact`；发布阶段不重新构建。

普通 push、PR 和标签推送只触发 CI。Release 工作流仅手动触发，避免本地
发布创建标签时又自动开始第二次发布。

## 失败后重试

保留日志中显示的原始候选 gem，使用 `--artifact` 重试。不要在同一版本下
重新构建不同字节的包。脚本校验已有 GitHub 附件，并从 GitHub / RubyGems
下载实际文件核对 SHA-256；遇到同版本不同字节或已撤回的 RubyGems 版本会拒绝。

GitHub 草稿可复用，缺失附件可补齐。若上传中断留下未完成附件，先确认没有
仍在运行的上传，移除该附件，再用同一个 gem 重试。已完成但不同字节的
附件不会被覆盖。RubyGems 成功而响应丢失时，重试会读取版本信息并核对原包。

源码、历史或包中发现敏感数据时，先处理问题并重新审核；已经公开的凭据
应在对应系统轮换。脚本不会跳过扫描，也不会自动清理历史或撤回远端版本。
