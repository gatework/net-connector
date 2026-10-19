# frozen_string_literal: true

require "expect/pty"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 在不记录回显的私有终端中响应一次 SSH 密码挑战。
        module SshAuthentication
          PASSWORD = /password:\s*\z/i
          REJECTED = /permission denied|authentication failed/i
          private_constant :PASSWORD, :REJECTED

          # 在同一认证期限内等待一次密码提示及连接结束；主连接可用性由调用方另行核对。
          def self.respond(arguments, password:)
            session = if defined?(Expect::Session)
                        Expect::Session.new(buffer_limit: 65_536, write_timeout: 5)
                      else
                        Expect.new(raw_pty: true, reset_timeout_on_read: false, buffer_limit: 65_536,
                                   preserve_buffer: false, log_stdout: false, log_listeners: false, debug_level: 0, write_timeout: 5)
                      end
            session.respond_to?(:transcript=) ? session.spawn(*arguments, raw: true) : session.spawn(*arguments)
            deadline = Expect.monotonic + 15
            reader = session.respond_to?(:expect_result) ? :expect_result : :expect
            challenge = session.public_send(reader, PASSWORD, REJECTED, timeout: [deadline - Expect.monotonic, 0].max)
            return false unless challenge.number == 1

            session.write(password + "\n")
            completion = session.public_send(reader, PASSWORD, REJECTED, timeout: [deadline - Expect.monotonic, 0].max)
            completion.error == :eof
          ensure
            session&.close
          end
        end
      end
    end
  end
end
