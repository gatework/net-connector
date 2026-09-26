# frozen_string_literal: true

require "coverage"

# 在测试加载库文件之前启用统计；仅记录已加载文件，避免把未加载文件
# 误报为已覆盖。CI 同时输出已加载文件数量，方便发现测试盲区。
Coverage.start(lines: true, branches: true)
require "minitest/autorun"

Minitest.after_run do
  library = "#{File.expand_path("../lib", __dir__)}/"
  measured = Coverage.result.select { |path, _| path.start_with?(library) }
  lines = measured.values.flat_map { |data| data.fetch(:lines).compact }
  branches = measured.values.flat_map { |data| data.fetch(:branches).values.flat_map(&:values) }
  total_files = Dir[File.join(library, "**/*.rb")].size
  puts "库覆盖率（仅统计已加载文件）：#{measured.size}/#{total_files} 个文件，" \
       "#{lines.count(&:positive?)}/#{lines.size} 行，" \
       "#{branches.count(&:positive?)}/#{branches.size} 个分支"
end
