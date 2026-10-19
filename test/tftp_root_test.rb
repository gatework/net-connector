# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco/tftp/root"

# 服务器文件名属于路径正文，不能因 URI 编码变成查询参数或片段。
class TftpRootTest < Minitest::Test
  Root = Net::Connector::Netdisco::Tftp::Root

  def test_server_paths_round_trip_without_reinterpreting_reserved_characters
    path = "/srv/备份 + 100%/config#part?revision[1].cfg"
    encoded = Root.encode_path(path)
    endpoint, decoded = Root.endpoint("ssh://reader@192.0.2.10#{encoded}")
    assert_equal path, decoded
    assert_nil endpoint.query
    assert_nil endpoint.fragment
    assert_includes encoded, "+"
    assert_includes encoded, "%25"
    assert_includes encoded, "%23"
    assert_includes encoded, "%3F"
  end

  def test_literal_percent_sequences_are_not_decoded_twice
    path = "/srv/literal%2Fname+backup.cfg"
    _endpoint, decoded = Root.endpoint("ssh://reader@192.0.2.10#{Root.encode_path(path)}")
    assert_equal path, decoded
  end
end
