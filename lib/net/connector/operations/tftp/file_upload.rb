# frozen_string_literal: true

require_relative "strategy"

module Net
  module Connector
    module Operations
      module Tftp
        # H3C 和华为共用已保存文件上传流程，源文件发现仍由厂商策略负责。
        class FileUpload < Strategy
          # 未指定目标名时，设备使用配置源文件的 basename。
          def default_path(source_file) = File.basename(source_file)

          # H3C 探测源文件之前先拒绝不支持的参数；探测本身不能放进纯校验钩子。
          def validate_options!(_target, source_file:, vrf: nil)
            raise ArgumentError, "TFTP file upload does not use vrf" unless vrf.nil?

            TftpTarget.validate_source_file!(source_file) unless source_file.nil?
          end

          # 指定文件的内容与格式未知，不能仅凭 .cfg 后缀声称是当前运行配置。
          def receipt_metadata(_target, source_file:, **)
            { configuration_kind: :saved_file, source_file: source_file, format: :unknown }
          end

          # 仅在调用方指定目标名时追加参数，保留设备原生命名行为。
          def script(target, source_file:, vrf: nil)
            validate_options!(target, source_file: source_file, vrf: vrf)
            TftpTarget.validate_source_file!(source_file)

            destination = target.explicit_path? ? " #{target.path}" : ""
            Script.new([Command.new("tftp #{target.host} put #{source_file}#{destination}", timeout: 180)])
          end

          # 只接受明确的成功消息、非零传输字节数或完整进度行。
          def complete?(result)
            completion_lines(result).any? { |line| completed_upload?(line) }
          end

          private

          # 两个厂商的上传完成消息使用相同的文本及进度格式。
          def completed_upload?(line)
            line.match?(/\A
              (?:File\s+)?(?:transfer|upload)(?:\s+(?:is|was))?\s+
              (?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?(?:\s+successfully)?)[.!]?
              \z/ix) ||
              line.match?(/\A[1-9]\d*\s+bytes?\s+sent(?:\s+in\s+[\d.]+\s+(?:secs?|seconds?))?[.!]?\z/i) ||
              completed_progress?(line)
          end
        end
      end
    end
  end
end
