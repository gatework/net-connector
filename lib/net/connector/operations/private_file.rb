# frozen_string_literal: true

require "tempfile"

module Net
  module Connector
    module Operations
      # 文件同步和目录项同步分别记录；原子可见不等于断电后仍能恢复新目录项。
      module PrivateFile
        Receipt = Data.define(:path, :state, :phase) do
          def initialize(path:, state:, phase:)
            unless path.is_a?(String) && !path.empty? && %i[not_committed committed durable].include?(state) &&
                   %i[resolve_parent temporary_file write file_sync rename directory_open directory_sync cleanup complete].include?(phase)
              raise ArgumentError, "invalid file write receipt"
            end
            super(path: path.dup.freeze, state: state, phase: phase)
          end

          def committed? = state != :not_committed
          def durable? = state == :durable
        end

        class WriteError < IOError
          attr_reader :receipt, :code, :underlying_type

          def initialize(receipt:, underlying_type:)
            raise ArgumentError, "receipt must be a file write receipt" unless receipt.instance_of?(Receipt)

            @receipt = receipt
            @underlying_type = underlying_type.dup.freeze
            @code, message = if receipt.durable?
                               [:file_finalize_failed, "file replacement is durable; finalization failed"]
                             elsif receipt.committed?
                               [:file_persistence_unconfirmed, "file replacement is committed; durability is unconfirmed"]
                             else
                               [:file_write_failed, "file write failed before replacement was committed"]
                             end
            super(message)
          end

          def inspect = "#<#{self.class} state=#{receipt.state} phase=#{receipt.phase}>"
        end

        class PersistenceError < WriteError; end

        class DirectorySyncUnsupported < WriteError
          def initialize(**options)
            super
            @code = :directory_sync_unsupported
          end

          def message = "file replacement is committed; directory synchronization is unsupported"
          alias to_s message
        end

        UNSUPPORTED_DIRECTORY_SYNC = [Errno::EINVAL, Errno::ENOSYS, Errno::ENOTSUP, Errno::EOPNOTSUPP,
                                      NotImplementedError].uniq.freeze
        private_constant :UNSUPPORTED_DIRECTORY_SYNC

        # 外部子类可重写消息或回执；只有本写入器定义的具体错误类型可提供完成事实。
        def self.receipt_error?(error)
          [WriteError, PersistenceError, DirectorySyncUnsupported].any? { |type| error.instance_of?(type) }
        end

        # 保留原路径返回值；失败时可从异常 receipt 判断目录项是否已经替换。
        def self.write(path, contents)
          write_receipt(path, contents)
          path
        end

        def self.write_receipt(path, contents)
          raise ArgumentError, "path must be a nonempty String" unless path.is_a?(String) && !path.empty?

          receipt = Receipt.new(path: File.expand_path(path), state: :not_committed, phase: :resolve_parent)
          directory = File.realpath(File.dirname(receipt.path))
          destination = File.join(directory, File.basename(receipt.path))
          receipt = receipt.with(phase: :temporary_file)
          Tempfile.create([".net-connector-", ".tmp"], directory) do |file|
            file.binmode
            file.chmod(0o600)
            receipt = receipt.with(phase: :write)
            file.write(contents)
            receipt = receipt.with(phase: :file_sync)
            file.flush
            file.fsync
            receipt = receipt.with(phase: :rename)
            File.rename(file.path, destination)
            receipt = receipt.with(state: :committed, phase: :directory_open)
            File.open(directory, File::RDONLY | File::NOFOLLOW) do |parent|
              raise IOError, "parent is not a directory" unless parent.stat.directory?

              receipt = receipt.with(phase: :directory_sync)
              parent.fsync
              receipt = receipt.with(state: :durable, phase: :cleanup)
            end
          end
          receipt.with(phase: :complete)
        rescue StandardError, NotImplementedError => error
          raise unless receipt

          unsupported = receipt.phase == :directory_sync && UNSUPPORTED_DIRECTORY_SYNC.any? { |type| error.is_a?(type) }
          klass = if unsupported
                    DirectorySyncUnsupported
                  elsif receipt.committed?
                    PersistenceError
                  else
                    WriteError
                  end
          raise klass.new(receipt: receipt, underlying_type: error.class.name.to_s), cause: nil
        end
      end
    end
  end
end
