# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "shellwords"
require "tmpdir"
require "io/wait"
require_relative "root"
require_relative "ssh_authentication"
require_relative "archive"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 在服务器目标锁内串行完成上传、核验与双端归档，不重放已经发送的设备命令。
        class SshArchive
          # 构造设备任务启动前的 SSH 认证预检错误，提示可用的凭据配置方式。
          class AuthenticationUnavailable < ArgumentError
            # 构造不含凭据值的认证不可用提示，在设备任务开始前拒绝执行。
            def initialize(password_configured: false)
              detail = if password_configured
                         "已读取 NC_TFTP_SSH_PASSWORD，但 SSH 认证或主连接建立失败；请检查账号、密码、主机密钥及网络。密码含 # 或 $ 时请在 .env 中用单引号包裹"
                       else
                         "请在项目根目录 .env 设置 NC_TFTP_SSH_PASSWORD，或配置可用的 SSH 密钥/agent"
                       end
              super("SSH 归档认证不可用：#{detail}。已停止，未连接设备。")
            end
          end

          # 服务器环境不可归档时在批次开始前拒绝，避免逐设备重复失败。
          class PreparationUnavailable < ArgumentError
            # 提示检查远端运行时及私有目录，不携带 SSH 输出或设备配置。
            def initialize
              super("SSH 归档目录预检失败：请检查服务器 python3、TFTP 根目录及写权限；archive、批次目录和 .net-connector-locks 须由 SSH 账号拥有且权限为 0700。已停止，未连接设备。")
            end
          end

          MAX_FRAME_BYTES = 90 * 1024 * 1024
          SESSION_LIMIT = 4
          WORKER = File.expand_path("ssh_archive_worker.py", __dir__)
          private_constant :MAX_FRAME_BYTES, :WORKER

          # 解析归档端点并初始化有界会话槽位；允许注入本地进程启动器验证协议。
          def initialize(directory:, root:, password: nil, launcher: nil)
            @uri, @root = Root.endpoint(root)
            unless password.nil? || (password.is_a?(String) && !password.match?(/[\r\n\0]/))
              raise ArgumentError, "NC_TFTP_SSH_PASSWORD must be a single-line string"
            end
            @password = password&.dup&.freeze
            @report_directory = File.expand_path(directory)
            FileUtils.mkdir_p(@report_directory, mode: 0o700)
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
            @launcher.call do |input, output, error, process|
              begin
                write_frame(input, root: @root, filename: filename, archive_name: archive_name, batch: @batch)
                expect_phase(output, "ready")
                outcome = yield filename
                receipt = outcome.backup
                unless receipt.is_a?(TftpReceipt) && receipt.path == filename
                  write_frame(input, action: "abort")
                  next outcome
                end
                outcome = outcome.with(started_at: started_at)
                write_frame(input, action: "verify")
                proof = expect_phase(output, "archived")
                outcome = retain_upload(outcome, proof, archive_name)
                if outcome.success?
                  write_frame(input, action: "cleanup", sha256: outcome.backup.server_sha256)
                  expect_phase(output, "complete")
                else
                  write_frame(input, action: "abort")
                end
                outcome
              ensure
                stop_process(input, output, error, process)
              end
            end
          rescue StandardError
            raise Archive::Failure.new(host: device.host), cause: nil unless outcome
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
            @launcher.call do |input, output, error, process|
              begin
                write_frame(input, root: @root, filename: "preflight.cfg", archive_name: "preflight.cfg", batch: @batch, action: "preflight")
                expect_phase(output, "ready")
              ensure
                stop_process(input, output, error, process)
              end
            end
          rescue StandardError
            raise PreparationUnavailable, cause: nil
          end

          # 先核对服务器正文与摘要，再保留远端归档路径；后续本地写入失败仍保留已有证据。
          def retain_upload(outcome, proof, archive_name)
            bytes = proof.fetch("data").unpack1("m0")
            digest = Digest::SHA256.hexdigest(bytes)
            unless bytes.bytesize.positive? && bytes.bytesize == proof.fetch("bytes") && digest == proof.fetch("sha256")
              raise Archive::Failure
            end
            receipt = outcome.backup.with(verification: :server_verified, server_sha256: digest, server_bytes: bytes.bytesize,
                                        archive_path: remote_path(proof.fetch("archive_path")))
            outcome = outcome.with(backup: receipt)
            path = File.join(@report_directory, "tftp", archive_name)
            FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
            Storage::AtomicFile.write(path, bytes)
            outcome = outcome.with(backup: receipt.with(local_path: path))
            raise Archive::Failure unless Storage::FileReader.fingerprint(path).sha256 == digest

            outcome
          rescue StandardError => error
            if Storage::AtomicFile.receipt_error?(error) && error.receipt.committed? && error.receipt.path == path
              outcome = outcome.with(backup: outcome.backup.with(local_path: path))
            end
            outcome.success? ? archive_failure(outcome) : outcome
          end

          # 保留设备和服务器回执，将归档收尾异常转换为可诊断的部分成功。
          def archive_failure(outcome)
            failure = Archive::Failure.new(host: outcome.device.host)
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
                at_exit { close }
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
                           "-M", "-o", "ControlPersist=60", "-fN", @uri.host]
              return false unless SshAuthentication.respond(arguments, password: @password)

              system(*ssh_arguments, "-O", "check", @uri.host, in: File::NULL, out: File::NULL, err: File::NULL)
            else
              system(*ssh_arguments, "-M", "-o", "ControlPersist=60", "-fN", @uri.host,
                     in: File::NULL, out: File::NULL, err: File::NULL)
            end
          rescue StandardError
            false
          end

          # 复用主连接启动一次归档事务进程，会话槽位限制由调用作用域管理。
          def open_ssh(&)
            prepare_master
            command = "python3 -u -c #{Shellwords.escape(File.read(WORKER))}"
            Open3.popen3(*ssh_arguments, @uri.host, command, &)
          end

          # 将已校验端点组装为独立 SSH 参数，固定严格主机密钥检查与连接超时。
          def ssh_arguments(batch_mode: true)
            ["ssh", "-T", "-S", @socket.to_s, "-o", "BatchMode=#{batch_mode ? "yes" : "no"}",
             "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
             "-p", (@uri.port || 22).to_s, "-l", @uri.user]
          end

          # 将路径或事务动作编码为单行 JSON 并刷新，协议帧不携带认证凭据。
          def write_frame(input, **values)
            input.write(JSON.generate(values) + "\n")
            input.flush
          end

          # 在总期限和帧大小上限内读取完整响应，拒绝断连、错误阶段及无效协议数据。
          def expect_phase(output, phase)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 280
            frame = +"".b
            loop do
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise Archive::Failure unless remaining.positive? && output.wait_readable(remaining)

              chunk = output.read_nonblock(65_536, exception: false)
              next if chunk == :wait_readable
              raise Archive::Failure if chunk.nil?

              frame << chunk
              raise Archive::Failure if frame.bytesize > MAX_FRAME_BYTES
              next unless frame.end_with?("\n")

              value = JSON.parse(frame)
              raise Archive::Failure unless value["ok"] == true && value["phase"] == phase

              return value
            end
          end

          # 将远端归档路径编码为无密码 SSH URI，使公开回执明确区分本地与服务器产物。
          def remote_path(path)
            uri = @uri.dup
            uri.path = Root.encode_path(path)
            uri.to_s
          end

          # 先关闭事务管道并等待子进程退出，超时后分级终止，促使服务器释放锁。
          def stop_process(input, output, error, process)
            [input, output, error].each { |io| io.close unless io.closed? }
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
