# frozen_string_literal: true

# 覆盖率只统计当前测试进程实际加载的源码；关键组缺失文件时直接失败，
# 不通过预加载源码或忽略未加载文件来抬高覆盖率。
class CoverageReport
  MINIMUM = 80
  GROUPS = {
    "核心引擎" => "net/connector/engine/**/*.rb",
    "脱敏与错误（含 Redactor）" => "net/connector/engine/{errors,redactor}.rb",
    "批量并发" => "net/connector/netdisco/worker.rb"
  }.freeze

  def initialize(result, library: File.expand_path("../lib", __dir__), output: $stdout, baseline: nil)
    @library = library
    @output = output
    @baseline = baseline
    @files = Dir[File.join(library, "**/*.rb")]
    @measured = result.select { |path, _| @files.include?(path) }
  end

  # 不保存源代码或异常正文；未加载文件单列，不能隐含算作已覆盖。
  def to_h
    { schema: 1, ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM,
      dependencies: Gem.loaded_specs.sort.to_h { |name, spec| [name, spec.version.to_s] },
      loaded_files: @measured.size, total_files: @files.size,
      unloaded_files: (@files - @measured.keys).map { |path| relative(path) },
      coverage: counts(@measured.keys), groups: group_counts, ratchet: ratchet,
      files: @measured.keys.sort.map { |path| file_counts(path) } }
  end

  # 所有关键组均须达到行、分支下限；空组和未采集到可执行行同样失败。
  def passed?
    @output.puts "库覆盖率（仅统计当前进程已加载文件）：#{@measured.size}/#{@files.size} 个文件，" \
                   "#{summary(@measured.keys)}"
    missing = @files - @measured.keys
    @output.puts "未加载文件（#{missing.size}）："
    missing.each { |path| @output.puts "  #{relative(path)}" }

    groups_passed = GROUPS.map do |name, pattern|
      files = Dir[File.join(@library, pattern)]
      counts = statistics(files)
      loaded = !files.empty? && (files - @measured.keys).empty?
      covered = counts[:lines].any? && counts.values.all? do |hits|
        hits.count(&:positive?) * 100 >= hits.size * MINIMUM
      end
      passed = loaded && covered
      @output.puts "覆盖率门槛 #{name}（行 / 分支均 >= #{MINIMUM}%）：#{summary(files)}，" \
                     "#{passed ? "通过" : "不达标（检查覆盖率及未加载文件）"}"
      passed
    end.all?
    comparison = ratchet
    @output.puts "NC-00 覆盖率比较：#{comparison[:status]}（仅相同 Ruby 描述/平台直接比较）"
    comparison.fetch(:regressions).each { |message| @output.puts "  #{message}" }
    groups_passed && comparison[:status] != :regression
  end

  private

  def relative(path) = path.delete_prefix("#{@library}/")

  def statistics(files)
    data = files.filter_map { |path| @measured[path] }
    { lines: data.flat_map { |item| item.fetch(:lines).compact },
      branches: data.flat_map { |item| item.fetch(:branches).values.flat_map(&:values) } }
  end

  def counts(files)
    statistics(files).transform_values { |hits| { hit: hits.count(&:positive?), total: hits.size } }
  end

  def group_counts
    GROUPS.to_h { |name, pattern| [name, counts(Dir[File.join(@library, pattern)])] }
  end

  def file_counts(path)
    data = @measured.fetch(path)
    uncovered = data.fetch(:branches).values.flat_map do |branches|
      branches.filter_map do |branch, hits|
        { kind: branch[0].to_s, line: branch[2], column: branch[3] } if hits.zero? && branch.is_a?(Array)
      end
    end
    { path: relative(path), **counts([path]),
      uncovered_lines: data.fetch(:lines).each_index.select { |index| data[:lines][index] == 0 }.map { |index| index + 1 },
      uncovered_branches: uncovered }
  end

  # Ruby 插桩与平台分支会改变分母；其他环境保留原 80% 门槛并输出数据，
  # 由维护者独立建立该环境的基线，不能自动把本次低覆盖写回基线。
  def ratchet
    return { status: :not_configured, regressions: [] } unless @baseline
    return { status: :not_comparable, regressions: [] } unless @baseline.fetch("ruby") == RUBY_DESCRIPTION

    measured = group_counts.merge("library" => counts(@measured.keys))
    regressions = @baseline.fetch("groups").flat_map do |name, metrics|
      metrics.filter_map do |kind, previous|
        current = measured.fetch(name).fetch(kind.to_sym)
        next if previous.fetch("total").zero?
        next if current[:total].positive? && current[:hit] * previous.fetch("total") >= previous.fetch("hit") * current[:total]

        "#{name} / #{kind}: #{current[:hit]}/#{current[:total]} < #{previous.fetch("hit")}/#{previous.fetch("total")}"
      end
    end
    { status: regressions.empty? ? :passed : :regression, regressions: regressions }
  end

  def summary(files)
    statistics(files).map do |kind, hits|
      covered = hits.count(&:positive?)
      percentage = hits.empty? ? "无可执行项" : format("%.2f%%", 100.0 * covered / hits.size)
      "#{covered}/#{hits.size} #{kind == :lines ? "行" : "分支"}（#{percentage}）"
    end.join("，")
  end
end
