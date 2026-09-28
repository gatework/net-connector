# 设备配置备份示例

在本目录运行脚本。普通 `ruby` 使用已安装的 net-connector gem；验证当前源码使用 `bundle exec ruby`。脚本自动读取项目根目录 `.env`。

| 入口 | 用途 |
| --- | --- |
| `backup.rb` | 从 Netdisco 获取清单，全量采集配置并保存本地文件 |
| `backup_tftp.rb` | 从 Netdisco 获取清单，批量让设备上传到 TFTP |
| `device_tftp.rb` | 通过 DEVICE_* 环境变量指定单台设备，上传到 TFTP |
| `review_tftp.rb` | 离线复核已完成的 TFTP 批次，生成 review.json 和 failed_hosts.txt |

```sh
ruby backup.rb --help
ruby backup.rb --concurrency 10
ruby backup.rb --sample 3 --verbose
ruby backup.rb --config examples/backup.yml
ruby backup_tftp.rb --help
ruby device_tftp.rb --help
ruby review_tftp.rb backups/2026-09-28_14-04-11
```

批量脚本的 `--config` 和备份目录相对项目根目录解析；离线复核的批次目录相对当前目录解析。配置文件 `backup.yml` 展示非敏感备份策略，`inventory_sql.yml` 展示 PostgreSQL 清单查询；凭据放在 `.env`、环境变量或密码提示中。

`backup.rb` / `backup_tftp.rb` 的流程为：读取参数和配置 → 创建 UTC+8 批次目录 → 建立清单连接 → 生成计划 → 并发执行 → 保存 JSON 和文本报告。默认全量，抽样须显式指定。

公共实现已进入 gem；参数、连接和报告属于 `Net::Connector::Netdisco`，目录管理属于 `Net::Connector::Storage`：

- `BackupRun#run`：统一批次编排，返回退出码。
- `CLI::Options.parse` / `.settings`：命令行参数、密码输入和环境覆盖。
- `Connection.build`：清单连接和设备凭据来源，可注入标准输入。
- `Net::Connector::Storage::BatchDirectory.create`：创建批次目录。
- `Report::Files.write`：原子保存统一 JSON 与文本报告，返回包含保存结果的 Report。
- `TftpVerification`：核验本机服务器文件，保留未核验上传回执。

`boot.rb` 只负责示例专用的 `.env` 加载和工作目录设置，不作为独立脚本运行。模块本身不加载 `.env`、不切换目录、不退出宿主进程。厂商协议、并发执行和配置采集仍由已有模块承担。

旧入口对应关系：netdisco_backup.rb → backup.rb；netdisco_tftp_backup.rb → backup_tftp.rb；tftp_backup.rb → device_tftp.rb；review_tftp_backup.rb → review_tftp.rb。请同步更新定时任务路径。

示例默认 `--success-policy selected`：只允许主动过滤和抽样跳过；未知厂商、缺少凭据、失败、部分成功和报告错误均返回非零。
`summary.json` 的逐台结果统一位于 `devices`，保留诊断字段；`events.jsonl` 逐台完成即刷新。
自定义 `NC_LOG_DIRECTORY` 会同步体现在报告的 `session_log` 中。

```sh
ruby backup_tftp.rb --tftp-root /srv/tftp --success-policy verified
```

提供本机或挂载的 TFTP 服务器目录后，批量示例以 `hostname-ip.<扩展名>` 上传，并把每台已核验文件保存到服务器的 `archive/<批次>/` 和本地的 `<批次目录>/tftp/`。TFTP 根目录仅作上传暂存区；成功归档后移除暂存文件。运行前已存在的同名文件先保留到该批次的 `previous/`。无需 SSH 登录或更改 TFTP 服务进程的根目录；部分厂商不支持上传到子目录，PAN-OS 还强制使用 `running-config.xml`。无法访问服务器目录时，远端文件名增加东八区批次标识和同秒序号，避免覆盖旧文件。PAN-OS 需要本机 TFTP 目录才能安全归档，否则该设备不发起上传并报 `tftp_history_unavailable`。没有本机目录的其他设备保留为未核验；`verified` 必须提供本机目录并核验所有选中设备的文件。

提供本机 TFTP 目录时，批量计划会选中所有符合条件的 PAN-OS 设备，并在上传和归档期间对固定文件名加锁；没有本机目录时仍按原有计划保留文件名冲突跳过。
