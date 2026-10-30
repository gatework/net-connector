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
            Expect.spawn(*arguments, raw: true, buffer_limit: 65_536, write_timeout: 5) do |session|
              deadline = Expect.monotonic + 15
              challenge = session.expect(PASSWORD, REJECTED, timeout: [deadline - Expect.monotonic, 0].max)
              next false unless challenge.match_number == 1

              session.write(password + "\n")
              completion = session.expect(PASSWORD, REJECTED, timeout: [deadline - Expect.monotonic, 0].max)
              completion.eof?
            end
          end
        end
      end
    end
  end
end
