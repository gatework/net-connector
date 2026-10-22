# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "../lib/net/connector/storage/batch_directory"

class DirectoryDurabilityTest < Minitest::Test
  def test_batch_creation_fails_before_use_when_new_ancestry_cannot_be_synced
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      original = File.method(:open)
      failure = lambda do |path, *args, **kwargs, &block|
        raise Errno::EIO if path == root
        original.call(path, *args, **kwargs, &block)
      end
      File.stub(:open, failure) do
        assert_raises(Errno::EIO) { Net::Connector::Storage::BatchDirectory.create(File.join(root, "new", "reports")) }
      end
    end
  end
end
