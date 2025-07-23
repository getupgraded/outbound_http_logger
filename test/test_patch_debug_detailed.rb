# frozen_string_literal: true

require 'test_helper'
require 'net/http'

# Load HTTP libraries for testing
begin
  require 'faraday'
rescue LoadError
  # Faraday not available
end

class TestPatchDebugDetailed < Minitest::Test
  def setup
    OutboundHTTPLogger.reset_configuration!
    OutboundHTTPLogger.reset_patches!
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all
  end

  def teardown
    OutboundHTTPLogger.reset_configuration!
    OutboundHTTPLogger.reset_patches!
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all
  end

  def test_faraday_patch_enabled_check
    skip 'Faraday not available' unless defined?(Faraday)

    # Enable logging and Faraday patch, but disable other patches to avoid interference
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.faraday_patch_enabled = true
      config.net_http_patch_enabled = false # Disable to avoid Faraday->Net::HTTP interference
    end

    # Verify patch is applied
    assert_predicate OutboundHTTPLogger::Patches::FaradayPatch, :applied?

    # Check configuration
    config = OutboundHTTPLogger.configuration

    assert_predicate config, :enabled?
    assert_predicate config, :faraday_patch_enabled?

    # Test the patch_enabled_for_library? method directly
    dummy_class = Class.new do
      include OutboundHTTPLogger::Patches::CommonPatchBehavior
    end
    dummy = dummy_class.new

    assert dummy.send(:patch_enabled_for_library?, 'faraday', config)

    # Get initial count before any requests
    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    # Make a request - should be logged
    stub_request(:get, 'http://example.com/faraday-test')
      .to_return(status: 200, body: 'success')

    conn = Faraday.new
    conn.get('http://example.com/faraday-test')

    after_first_request_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_operator after_first_request_count, :>, initial_count, 'First request should have been logged'

    # Now disable the patch at runtime
    config.faraday_patch_enabled = false

    # Check configuration again
    refute_predicate config, :faraday_patch_enabled?

    # Test the patch_enabled_for_library? method again
    refute dummy.send(:patch_enabled_for_library?, 'faraday', config)

    # Make another request - should NOT be logged
    stub_request(:get, 'http://example.com/faraday-test2')
      .to_return(status: 200, body: 'success')

    conn.get('http://example.com/faraday-test2')

    # Should not have increased
    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_equal after_first_request_count, final_count, "Expected count to remain #{after_first_request_count}, but got #{final_count}"
  end

  def test_configuration_check_in_patch
    skip 'Faraday not available' unless defined?(Faraday)

    # Enable logging and Faraday patch, but disable other patches to avoid interference
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.faraday_patch_enabled = true
      config.net_http_patch_enabled = false # Disable to avoid Faraday->Net::HTTP interference
    end

    # Verify patch is applied
    assert_predicate OutboundHTTPLogger::Patches::FaradayPatch, :applied?

    # Get initial count before any requests
    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    # Make a request - should be logged
    stub_request(:get, 'http://example.com/test1')
      .to_return(status: 200, body: 'success')

    conn = Faraday.new
    conn.get('http://example.com/test1')

    after_first_request_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_operator after_first_request_count, :>, initial_count, 'First request should have been logged'

    # Disable the patch
    OutboundHTTPLogger.configuration.faraday_patch_enabled = false

    # Make another request - should NOT be logged
    stub_request(:get, 'http://example.com/test2')
      .to_return(status: 200, body: 'success')

    conn.get('http://example.com/test2')

    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_equal after_first_request_count, final_count, "Expected count to remain #{after_first_request_count}, but got #{final_count}. Patch may not be checking configuration correctly."
  end
end
