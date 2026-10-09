# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "../storage/private_file"

module Net
  module Connector
    module Netdisco
      module ResultStore
        # 每批保存一份私有 JSON 报告，通过重命名防止半写文件。
        class Json
          # 以临时文件和重命名原子写入私有 JSON 报告。
          def write(report, directory:)
            destination = File.expand_path(directory)
            FileUtils.mkdir_p(destination, mode: 0o700)
            filename = "netdisco-#{report.mode}-#{report.started_at.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}.json"
            path = File.join(destination, filename)
            Storage::PrivateFile.write(path, JSON.pretty_generate(report.summary)).path
          end
        end

        # 数据库仓储由调用方提供，可使用 Active Record 或其他对象。
        # 仓储须实现 create!，本项目不负责数据库表结构。
        class Database
          # 校验并保存调用方提供的数据库仓储。
          def initialize(repository:)
            raise ArgumentError, "repository must respond to create!" unless repository.respond_to?(:create!)

            @repository = repository
          end

          # 把批量摘要写入调用方仓储并返回记录位置。
          def write(report, **_options)
            record = @repository.create!(report.summary)
            record.respond_to?(:id) ? "database:#{record.id}" : "database"
          end
        end
      end
    end
  end
end
