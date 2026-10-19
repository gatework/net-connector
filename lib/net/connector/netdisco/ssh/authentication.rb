# frozen_string_literal: true

require "expect/pty"

module Net
  module Connector
    module Netdisco
      module SSH
        # 在不记录回显的私有终端中响应一次 SSH 密码挑战。
        module Authentication
          PASSWORD = /password:\s*\z/i
          REJECTED = /permission denied|authentication failed/i
          private_constant :PASSWORD, :REJECTED

          # 在同一认证期限内等待一次密码提示及连接结束；主连接可用性由调用方另行核对。
          def self.respond(arguments, password:)
            session = Expect::Session.new(buffer_limit: 65_536, write_timeout: 5)
            session.spawn(*arguments, raw: true)
            deadline = Expect.monotonic + 15
            challenge = session.expect(PASSWORD, REJECTED, timeout: [deadline - Expect.monotonic, 0].max)
            return false unless challenge.number == 1

            session.write(password + "\n")
            completion = session.expect(PASSWORD, REJECTED, timeout: [deadline - Expect.monotonic, 0].max)
            completion.error == :eof
          ensure
            session&.close
          end
        end
      end
    end
  end
end
