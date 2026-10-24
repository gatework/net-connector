# frozen_string_literal: true

require_relative "../../../storage/directory"

require "digest"
require "open3"
require "securerandom"
require "shellwords"
require "tmpdir"
require_relative "../../tftp/root"
require_relative "../authentication"
require_relative "../../tftp/archive"
require_relative "protocol"

module Net
  module Connector
    module Netdisco
      module SSH
        # SSH 归档的客户端、连接调度与服务器事务实现。
        module Archive
          # 在服务器目标锁内串行完成上传、核验与双端归档，不重放已经发送的设备命令。
          class Client
            # 构造设备任务启动前的 SSH 认证预检错误，提示可用的凭据配置方式。
            class AuthenticationUnavailable < ArgumentError
              # 构造不含凭据值的认证不可用提示，在设备任务开始前拒绝执行。
              def initialize(password_configured: false)
                detail = if password_configured
                           "NC_TFTP_SSH_PASSWORD was read, but SSH authentication or master connection setup failed; check username, password, host key and network. Wrap passwords containing # or $ in single quotes in .env"
                         else
                           "Set NC_TFTP_SSH_PASSWORD in the project root .env, or configure a working SSH key/agent"
                         end
                super("SSH archive authentication unavailable: #{detail}. Stopped without connecting to devices.")
              end
            end

            # 服务器环境不可归档时在批次开始前拒绝，避免逐设备重复失败。
            class PreparationUnavailable < ArgumentError
              # 提示检查远端运行时及私有目录，不携带 SSH 输出或设备配置。
              def initialize
                super("SSH archive directory preflight failed: check server python3, the TFTP root and write permissions; archive, batch directories and .net-connector-locks must be owned by the SSH user with mode 0700. Stopped without connecting to devices.")
              end
            end

            SESSION_LIMIT = 4
            WORKER = File.expand_path("worker.py", __dir__)
            ACTIVE_CLIENTS = {}
            ACTIVE_CLIENTS_MUTEX = Mutex.new
            private_constant :WORKER, :ACTIVE_CLIENTS, :ACTIVE_CLIENTS_MUTEX

            # 退出处理只持有仍需清理的连接；已关闭的批次与凭据可由 GC 回收。
            at_exit do
              clients = ACTIVE_CLIENTS_MUTEX.synchronize { ACTIVE_CLIENTS.keys }
              failure = nil
              clients.each do |client|
                begin
                  client.close
                rescue Exception => error # rubocop:disable Lint/RescueException -- 一个连接失败仍须关闭其余连接。
                  failure ||= error
                end
              end
              raise failure if failure
            end

            # 解析归档端点并初始化有界会话槽位；允许注入本地进程启动器验证协议。
            def initialize(directory:, root:, password: nil, launcher: nil)
              @uri, @root = Tftp::Root.endpoint(root)
              unless password.nil? || (password.is_a?(String) && !password.match?(/[\r\n\0]/))
                raise ArgumentError, "NC_TFTP_SSH_PASSWORD must be a single-line string"
              end
              @password = password&.dup&.freeze
              @report_directory = File.expand_path(directory)
              Storage::Directory.prepare(@report_directory)
              @batch = "#{Time.now.getlocal("+08:00").strftime("%Y-%m-%d_%H-%M-%S")}-ssh-#{SecureRandom.hex(8)}"
              @launcher = launcher || method(:open_ssh)
              @custom_launcher = !launcher.nil?
              @master_mutex = Mutex.new
              @slots = SizedQueue.new(SESSION_LIMIT)
              SESSION_LIMIT.times { @slots << true }
            end

            # 返回设备原生上传名，实际上传前由服务器锁保护固定目标。
            def upload_filename(device) = device.tftp_filename

            # 在启动并发设备任务和刷新进度之前完成 SSH 归档认证。
            def prepare
              prepare_master unless @custom_launcher
              prepare_archive
            end

            # 持有服务器锁完成一次上传、核验与双端归档，失败时保留回执且不重试设备导出。
            def upload_and_archive(device, started_at:)
              outcome = nil
              acquired = @slots.pop
              filename = TftpTarget.validate_path!(upload_filename(device))
              archive_name = "#{device.backup_filename(style: :hostname_ip).delete_suffix(".txt")}#{File.extname(filename)}"
              with_process do |protocol|
                protocol.send_frame(root: @root, filename: filename, archive_name: archive_name, batch: @batch)
                protocol.expect_phase("ready")
                outcome = yield filename
                receipt = outcome.backup
                unless receipt.is_a?(TftpReceipt) && receipt.path == filename
                  protocol.send_frame(action: "abort")
                  next outcome
                end
                outcome = outcome.with(started_at: started_at)
                protocol.send_frame(action: "verify")
                proof = protocol.expect_phase("archived")
                outcome = retain_upload(outcome, protocol, proof, archive_name)
                if outcome.success?
                  protocol.send_frame(action: "cleanup", sha256: outcome.backup.server_sha256)
                  protocol.expect_phase("complete")
                else
                  protocol.send_frame(action: "abort")
                end
                outcome
              end
            rescue StandardError
              raise Tftp::Archive::Failure.new(host: device.host), cause: nil unless outcome
              return outcome unless outcome.success?

              archive_failure(outcome)
            ensure
              @slots << true if acquired
            end

            # 关闭本归档器私有的 SSH 主连接，并始终尝试删除控制套接字目录。
            def close
              return unless @master_directory

              Thread.handle_interrupt(Exception => :never) do
                begin
                  system(*ssh_arguments, "-O", "exit", @uri.host, out: File::NULL, err: File::NULL) if File.socket?(@socket)
                rescue Exception => error # rubocop:disable Lint/RescueException -- 关闭 SSH 失败仍须回收私有目录。
                  primary = error
                ensure
                  begin
                    FileUtils.remove_entry_secure(@master_directory) if File.directory?(@master_directory)
                  rescue Exception => error # rubocop:disable Lint/RescueException -- 保留先发生的清理故障。
                    primary ||= error
                  ensure
                    @master_directory = @socket = nil
                    ACTIVE_CLIENTS_MUTEX.synchronize { ACTIVE_CLIENTS.delete(self) }
                  end
                end
                raise primary if primary
              end
            rescue SystemCallError
              # 私有控制套接字清理失败不改变此前已归档文件的完成事实。
              nil
            end

            private

            # 用实际事务进程预检目录与写入边界，不读取或上传任何设备文件。
            def prepare_archive
              with_process do |protocol|
                protocol.send_frame(root: @root, filename: "preflight.cfg", archive_name: "preflight.cfg", batch: @batch, action: "preflight")
                protocol.expect_phase("ready")
              end
            rescue StandardError
              raise PreparationUnavailable, cause: nil
            end

            # 先核对服务器正文与摘要，再保留远端归档路径；后续本地写入失败仍保留已有证据。
            def retain_upload(outcome, protocol, proof, archive_name)
              receipt = outcome.backup.with(verification: :server_verified, server_sha256: proof.fetch("sha256"), server_bytes: proof.fetch("bytes"),
                                          archive_path: remote_path(proof.fetch("archive_path")))
              path = File.join(@report_directory, "tftp", archive_name)
              persist_upload(path) do |file|
                failure = receive_upload(protocol, receipt, file)
                outcome = outcome.with(backup: receipt)
                raise failure if failure
              end
              outcome = outcome.with(backup: receipt.with(local_path: path))
              raise Tftp::Archive::Failure unless Storage::FileReader.fingerprint(path).sha256 == receipt.server_sha256

              outcome
            rescue StandardError => error
              if Storage::AtomicFile.receipt_error?(error) && error.receipt.committed? && error.receipt.path == path
                outcome = outcome.with(backup: outcome.backup.with(local_path: path))
              end
              outcome.success? ? archive_failure(outcome) : outcome
            end

            # 本地准备失败仍接收并核验服务器正文；已经开始接收的失败事务不能重读或重写。
            def persist_upload(path)
              received = false
              Storage::Directory.prepare(File.dirname(path))
              Storage::AtomicFile.write_stream(path) do |file|
                received = true
                yield file
              end
            rescue StandardError
              yield nil unless received
              raise
            end

            # 逐块核对摘要，首次写盘错误后只继续读取；完整交付确认后才返回写盘故障。
            def receive_upload(protocol, receipt, file)
              digest = Digest::SHA256.new
              failure = nil
              protocol.read_payload(receipt.server_bytes) do |chunk|
                digest << chunk
                next unless file && !failure

                begin
                  raise IOError, "incomplete archive write" unless file.write(chunk) == chunk.bytesize
                rescue StandardError => error
                  failure = error
                end
              end
              raise Tftp::Archive::Failure unless digest.hexdigest == receipt.server_sha256

              failure
            end

            # 保留设备和服务器回执，将归档收尾异常转换为可诊断的部分成功。
            def archive_failure(outcome)
              failure = Tftp::Archive::Failure.new(host: outcome.device.host)
              outcome.with(status: :reported_with_error, error_code: failure.code, error_type: failure.class.name,
                           diagnostic: Diagnostic.from(failure, backup: outcome.backup))
            end

            # 建立或复用私有 SSH 主连接；缺少可用认证时明确拒绝，不隐式询问密码。
            def prepare_master
              @master_mutex.synchronize do
                return if @master_directory
                raise AuthenticationUnavailable.new(password_configured: !@password.nil?) if @master_failed

                begin
                  # 先登记临时目录所有权再递送取消，保证认证中断后仍能回收目录。
                  Thread.handle_interrupt(Exception => :never) do
                    @master_directory = Dir.mktmpdir("nc-tftp-", "/tmp")
                    @socket = File.join(@master_directory, "ssh")
                  end
                  unless authenticate_master
                    @master_failed = true
                    raise AuthenticationUnavailable.new(password_configured: !@password.nil?)
                  end
                  ACTIVE_CLIENTS_MUTEX.synchronize { ACTIVE_CLIENTS[self] = true }
                  prepared = true
                rescue Exception => error # rubocop:disable Lint/RescueException -- 清理后仍传播最先发生的故障或取消。
                  primary = error
                  raise
                ensure
                  unless prepared
                    begin
                      Thread.handle_interrupt(Exception => :never) { close }
                    rescue Exception => error # rubocop:disable Lint/RescueException -- 清理失败不能替换原始认证故障。
                      raise error unless primary
                    end
                  end
                end
              end
            end

            # 通过私有终端传递密码，或使用密钥认证；独立检查 SSH 主连接是否可用。
            def authenticate_master
              if @password
                arguments = [*ssh_arguments(batch_mode: false), "-o", "NumberOfPasswordPrompts=1",
                             "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no",
                             "-M", "-o", "ControlPersist=yes", "-fN", @uri.host]
                return false unless SSH::Authentication.respond(arguments, password: @password)

                system(*ssh_arguments, "-O", "check", @uri.host, in: File::NULL, out: File::NULL, err: File::NULL)
              else
                system(*ssh_arguments, "-M", "-o", "ControlPersist=yes", "-fN", @uri.host,
                       in: File::NULL, out: File::NULL, err: File::NULL)
              end
            rescue StandardError
              false
            end

            # 返回事务管道和等待线程，由调用作用域唯一负责关闭、终止及回收。
            def open_ssh
              command = "python3 -u -c #{Shellwords.escape(File.read(WORKER))}"
              Open3.popen3(*ssh_arguments, @uri.host, command)
            end

            # 将已校验端点组装为独立 SSH 参数，固定严格主机密钥检查与连接超时。
            def ssh_arguments(batch_mode: true)
              ["ssh", "-T", "-S", @socket.to_s, "-o", "BatchMode=#{batch_mode ? "yes" : "no"}",
               "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
               "-p", (@uri.port || 22).to_s, "-l", @uri.user]
            end

            # 每次事务独占进程与协议状态，主故障或非局部退出不能被普通清理错误覆盖。
            def with_process
              handles = nil
              prepare_master unless @custom_launcher
              completed = false
              # 取得资源与登记所有权之间暂缓取消；事务本身仍可立即中断。
              Thread.handle_interrupt(Exception => :never) { handles = @launcher.call }
              result = yield Protocol.new(handles[0], handles[1])
              completed = true
              result
            rescue Exception # rubocop:disable Lint/RescueException -- 返回前递送的取消仍属于事务主控制流。
              completed = false
              raise
            ensure
              begin
                stop_process(*handles) if handles
              rescue Exception # rubocop:disable Lint/RescueException -- 取消和非局部退出均保留原始控制流。
                raise if completed
              end
            end

            # 将远端归档路径编码为无密码 SSH URI，使公开回执明确区分本地与服务器产物。
            def remote_path(path)
              uri = @uri.dup
              uri.path = Tftp::Root.encode_path(path)
              uri.to_s
            end

            # 先关闭事务管道并等待子进程退出，超时后分级终止，促使服务器释放锁。
            def stop_process(input, output, error, process)
              Thread.handle_interrupt(Exception => :never) do
                failure = nil
                [input, output, error].each do |io|
                  begin
                    io.close unless io.closed?
                  rescue Exception => caught # rubocop:disable Lint/RescueException -- 单个关闭失败仍须回收其余管道和进程。
                    failure ||= caught
                  end
                end
                begin
                  reap_process(process)
                rescue Exception => caught # rubocop:disable Lint/RescueException -- 保留先发生的清理故障。
                  failure ||= caught
                end
                raise failure if failure
              end
            end

            # 为正常退出保留短暂宽限，随后终止仍未退出的事务进程并回收等待线程。
            def reap_process(process)
              return if process.join(2)

              Process.kill("TERM", process.pid)
              return if process.join(1)

              Process.kill("KILL", process.pid)
              process.join
            rescue Errno::ESRCH
              process.join
            end
          end
        end
      end
    end
  end
end
