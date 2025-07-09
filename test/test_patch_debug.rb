# frozen_string_literal: true

require 'test_helper'
require 'net/http'

class TestPatchDebug < Minitest::Test
  def setup
    super # Call TestHelpers setup to ensure table exists
    OutboundHTTPLogger.reset_configuration!
    OutboundHTTPLogger.reset_patches!
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all
  end

  def teardown
    OutboundHTTPLogger.reset_configuration!
    OutboundHTTPLogger.reset_patches!
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all
  end

  def test_patch_enabled_check
    # Enable logging and Net::HTTP patch
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
    end

    # Verify patch is applied
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?

    # Make a request - should be logged
    stub_request(:get, 'http://example.com/test1')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/test1')
    Net::HTTP.get(uri)

    assert_equal 1, OutboundHTTPLogger::Models::OutboundRequestLog.count

    # Now disable the patch at runtime
    OutboundHTTPLogger.configuration.net_http_patch_enabled = false

    # Make another request - should NOT be logged
    stub_request(:get, 'http://example.com/test2')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/test2')
    Net::HTTP.get(uri)

    # Should still be only 1 log entry
    assert_equal 1, OutboundHTTPLogger::Models::OutboundRequestLog.count
  end

  def test_patch_enabled_for_library_method
    config = OutboundHTTPLogger.configuration
    config.net_http_patch_enabled = true

    # Create a dummy object that includes CommonPatchBehavior to test the method
    dummy_class = Class.new do
      include OutboundHTTPLogger::Patches::CommonPatchBehavior
    end
    dummy = dummy_class.new

    assert dummy.send(:patch_enabled_for_library?, 'net_http', config)

    config.net_http_patch_enabled = false

    refute dummy.send(:patch_enabled_for_library?, 'net_http', config)
  end
end
