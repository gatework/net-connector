# frozen_string_literal: true

# 复核已结束的 TFTP 批次，不改写原始摘要。
# H3C 进度达到 100% 只算设备回显证据，不代表已回读服务器文件。

require "json"
require "fileutils"

if ARGV == ["--help"] || ARGV == ["-h"]
  puts "用法：ruby review_tftp.rb 批次目录（离线生成 review.json 和 failed_hosts.txt）"
  exit
end
abort "用法：ruby review_tftp.rb 批次目录" unless ARGV.size == 1

directory = File.expand_path(ARGV.fetch(0))
summary = JSON.parse(File.read(File.join(directory, "summary.json")))
plan = JSON.parse(File.read(File.join(directory, "plan.json")))
progress = []
failures = []
skipped = []

items = summary.key?("devices") ? summary.fetch("devices") : summary.fetch("outcomes")
items.each do |item|
  if item.fetch("status") == "remote_filename_collision"
    skipped << item.slice("host", "name", "vendor", "status")
    next
  end
  next unless item.fetch("status") == "failed"

  session_log = item["session_log"]
  if item.fetch("vendor") == "h3c" && item["error_code"] == "transfer_unconfirmed" &&
     session_log && File.file?(session_log)
    output = File.binread(session_log)
    completed = output.match(/^100\s+([1-9]\d*(?:\.\d+)?[kMG]?)\s+0\s+0\s+100\s+\1\b/in)
    if completed
      progress << { host: item.fetch("host"), name: item["name"], reported_size: completed[1],
                    remote_path: item.fetch("remote_path"), session_log: session_log,
                    server_file_verified: false }
      next
    end
  end
  failures << item.slice("host", "name", "vendor", "error_code", "error_type", "session_log")
end

report = {
  source_summary: File.join(directory, "summary.json"),
  inventory_total: plan.fetch("total"),
  inventory_issues: plan.fetch("inventory_issues") { plan.fetch("issues") },
  selected: plan.fetch("selected_count") { plan.fetch("selected").size },
  device_confirmed_uploads: summary.fetch("counts").fetch("reported_uploaded", 0),
  h3c_complete_progress_from_session_log: progress.size,
  remaining_failures: failures.size,
  skipped_filename_collisions: skipped.size,
  server_files_verified: items.count { |item| item["server_file_verified"] },
  failure_groups: failures.group_by { |item| [item.fetch("vendor"), item["error_code"]] }
                          .map { |(vendor, code), items| { vendor: vendor, error_code: code, count: items.size } }
                          .sort_by { |group| [-group.fetch(:count), group.fetch(:vendor)] },
  h3c_complete_progress: progress,
  failures: failures,
  skipped: skipped
}

File.write(File.join(directory, "review.json"), JSON.pretty_generate(report), mode: "w", perm: 0o600)
File.write(File.join(directory, "failed_hosts.txt"),
           failures.map { |item| [item.fetch("vendor"), item.fetch("host"), item["error_code"]].join("\t") }
                   .join("\n") + "\n", mode: "w", perm: 0o600)
puts JSON.generate(report.reject { |key, _value| %i[h3c_complete_progress failures skipped].include?(key) })
