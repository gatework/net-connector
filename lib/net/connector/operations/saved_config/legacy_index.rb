# frozen_string_literal: true

require_relative "../../engine/errors"
require_relative "../safe_file"

module Net
  module Connector
    class SavedConfigChanged < Error; end

    module Operations
      class SavedConfig
        # 每批只发布一份只读目录快照。记录文件身份而不读取正文；不跨批次缓存。
        class LegacyIndex
          Entry = Data.define(:name, :identity, :regular)
          EMPTY = [].freeze

          def initialize(directory)
            @directory = directory
            @mutex = Mutex.new
            @entries = nil
            @failed = false
          end

          def candidates(filename)
            @mutex.synchronize do
              raise IOError, "unable to index saved configurations", cause: nil if @failed

              @entries ||= snapshot
              @entries.fetch(filename, EMPTY)
            rescue IOError, SystemCallError
              @failed = true
              raise IOError, "unable to index saved configurations", cause: nil
            end
          end

          # 目录快照不是锁：同一 FD 读取前后及最终目录项都必须仍匹配快照。
          # 非合作写入者仍可在检查之后修改文件，调用方必须保护整个备份目录。
          def open(entry)
            path = File.join(@directory, entry.name)
            verify!(entry, File.lstat(path))
            SafeFile.open(path) do |file, stat|
              verify!(entry, stat)
              value = yield path, file, stat
              verify!(entry, file.stat)
              verify!(entry, File.lstat(path))
              value
            end
          rescue IOError, SystemCallError
            changed!
          rescue ArgumentError
            raise unless entry.regular

            changed!
          end

          private

          def snapshot
            entries = {}
            Dir.children(@directory).each do |name|
              filename = canonical_suffix(name)
              next unless filename

              (entries[filename] ||= []) << snapshot_entry(name)
            end
            entries.each_value(&:freeze)
            entries.freeze
          end

          # 下划线仅还原地址部分，IPv6 zone 中的下划线保持原义；合法性仍由 IPAddr 判断。
          def canonical_suffix(name)
            suffix = name.b[/-([0-9a-f_.]+(?:%[a-z0-9_.-]+)?)\.txt\z/in, 1]
            return unless suffix

            address, zone = suffix.split("%", 2)
            host = address.tr("_", ":")
            host += "%#{zone}" if zone
            SavedConfig.filename(host).freeze
          rescue ArgumentError
            nil
          end

          def snapshot_entry(name)
            stat = File.lstat(File.join(@directory, name))
            Entry.new(name: name.freeze, identity: identity(stat), regular: stat.file?)
          rescue SystemCallError
            # 列表与 lstat 之间消失的候选仍占据该身份，不能把后来出现的文件当作旧快照。
            Entry.new(name: name.freeze, identity: nil, regular: false)
          end

          def identity(stat)
            [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime.to_r, stat.ctime.to_r].freeze
          end

          def verify!(entry, stat)
            changed! unless entry.identity == identity(stat)
          end

          def changed!
            raise SavedConfigChanged.new("legacy saved configuration changed or became unavailable after indexing",
                                         code: :saved_config_changed, phase: :backup), cause: nil
          end
        end

        private_constant :LegacyIndex
      end
    end
  end
end
