# frozen_string_literal: true

require 'test_helper'
require 'net/http'

# Load HTTP libraries for testing
begin
  require 'faraday'
rescue LoadError
  # Faraday not available
end

begin
  require 'httparty'
rescue LoadError
  # HTTParty not available
end

class TestPatchRuntimeBehavior < Minitest::Test
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

  def test_net_http_patch_respects_runtime_disable
    # First enable and apply the patch
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
    end

    # Verify patch is applied
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?

    # Make a request - should be logged
    stub_request(:get, 'http://example.com/test')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/test')
    Net::HTTP.get(uri)

    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_equal 1, initial_count

    # Now disable the patch at runtime
    OutboundHTTPLogger.disable_patch('net_http')

    # Patch should still be applied but inactive
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?
    refute_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?

    # Make another request - should NOT be logged
    stub_request(:get, 'http://example.com/test2')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/test2')
    Net::HTTP.get(uri)

    # Should still be only 1 log entry
    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_equal initial_count, final_count
  end

  def test_faraday_patch_respects_runtime_disable
    skip 'Faraday not available' unless defined?(Faraday)

    # First enable and apply the patch, but disable other patches to avoid interference
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
    stub_request(:get, 'http://example.com/faraday-test')
      .to_return(status: 200, body: 'success')

    conn = Faraday.new
    conn.get('http://example.com/faraday-test')

    after_first_request_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_operator after_first_request_count, :>, initial_count, 'First request should have been logged'

    # Now disable the patch at runtime
    OutboundHTTPLogger.disable_patch('faraday')

    # Patch should still be applied but inactive
    assert_predicate OutboundHTTPLogger::Patches::FaradayPatch, :applied?
    refute_predicate OutboundHTTPLogger.configuration, :faraday_patch_enabled?

    # Make another request - should NOT be logged
    stub_request(:get, 'http://example.com/faraday-test2')
      .to_return(status: 200, body: 'success')

    conn.get('http://example.com/faraday-test2')

    # Should not have increased
    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_equal after_first_request_count, final_count
  end

  def test_httparty_patch_respects_runtime_disable
    # HTTParty patch has been removed - HTTParty requests are now handled by Net::HTTP patch
    # Configure with Net::HTTP enabled to handle HTTParty requests
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true # Enable to handle HTTParty requests
      config.faraday_patch_enabled = false
    end

    # HTTParty patch removed - HTTParty requests are now logged via Net::HTTP patch
    # Verify Net::HTTP patch is applied (which will handle HTTParty requests)
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?

    # Get initial count before any requests
    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    # Make a request - should be logged
    stub_request(:get, 'http://example.com/httparty-test')
      .to_return(status: 200, body: 'success')

    HTTParty.get('http://example.com/httparty-test')

    after_first_request_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_operator after_first_request_count, :>, initial_count, 'First request should have been logged'

    # Now try to disable the HTTParty patch at runtime (should warn and do nothing)
    OutboundHTTPLogger.disable_patch('httparty')

    # Net::HTTP patch should still be applied and active (HTTParty requests go through it)
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?
    assert_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?

    # Make another request - should STILL be logged (via Net::HTTP patch)
    stub_request(:get, 'http://example.com/httparty-test2')
      .to_return(status: 200, body: 'success')

    HTTParty.get('http://example.com/httparty-test2')

    # Should have increased (HTTParty requests still logged via Net::HTTP)
    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_equal after_first_request_count + 1, final_count
  end

  def test_selective_patch_application_prevents_logging
    # Configure with only Net::HTTP enabled
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = false
    end

    # Only Net::HTTP patch should be applied
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?
    refute_predicate OutboundHTTPLogger::Patches::FaradayPatch, :applied?

    # Get initial count before any requests
    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    # Net::HTTP request should be logged
    stub_request(:get, 'http://example.com/nethttp')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/nethttp')
    Net::HTTP.get(uri)

    after_nethttp_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_operator after_nethttp_count, :>, initial_count, 'Net::HTTP request should have been logged'

    # Faraday request WILL be logged because Faraday uses Net::HTTP internally
    # and the Net::HTTP patch is enabled (even though Faraday patch is not applied)
    if defined?(Faraday)
      stub_request(:get, 'http://example.com/faraday')
        .to_return(status: 200, body: 'success')

      conn = Faraday.new
      conn.get('http://example.com/faraday')

      # Should have increased because Faraday uses Net::HTTP internally
      count_after_faraday = OutboundHTTPLogger::Models::OutboundRequestLog.count

      assert_operator count_after_faraday, :>, after_nethttp_count, 'Faraday request should be logged via Net::HTTP patch'
    end

    # HTTParty request WILL also be logged because HTTParty uses Net::HTTP internally
    # and the Net::HTTP patch is enabled (even though HTTParty patch is not applied)
    return unless defined?(HTTParty)

    count_before_httparty = OutboundHTTPLogger::Models::OutboundRequestLog.count

    stub_request(:get, 'http://example.com/httparty')
      .to_return(status: 200, body: 'success')

    HTTParty.get('http://example.com/httparty')

    # Should have increased because HTTParty uses Net::HTTP internally
    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    assert_operator final_count, :>, count_before_httparty, 'HTTParty request should be logged via Net::HTTP patch'
  end

  def test_runtime_enable_patch_applies_immediately
    # Start with patch disabled
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = false
    end

    # Patch should not be applied
    refute_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?

    # Enable patch at runtime
    OutboundHTTPLogger.enable_patch('net_http')

    # Patch should now be applied
    assert_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?
    assert_predicate OutboundHTTPLogger.configuration, :net_http_patch_enabled?

    # Request should be logged
    stub_request(:get, 'http://example.com/test')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/test')
    Net::HTTP.get(uri)

    assert_equal 1, OutboundHTTPLogger::Models::OutboundRequestLog.count
  end

  def test_global_disable_overrides_individual_patch_settings
    # Configure with patches enabled individually but globally disabled
    OutboundHTTPLogger.configure do |config|
      config.enabled = false
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = true
    end

    # No patches should be applied when globally disabled
    refute_predicate OutboundHTTPLogger::Patches::NetHTTPPatch, :applied?
    refute_predicate OutboundHTTPLogger::Patches::FaradayPatch, :applied?

    # No requests should be logged
    stub_request(:get, 'http://example.com/test')
      .to_return(status: 200, body: 'success')

    uri = URI('http://example.com/test')
    Net::HTTP.get(uri)

    assert_equal 0, OutboundHTTPLogger::Models::OutboundRequestLog.count
  end

  def test_patch_status_reflects_runtime_changes
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
    end

    status = OutboundHTTPLogger.patch_status

    assert status['Net::HTTP'][:enabled]
    assert status['Net::HTTP'][:applied]
    assert status['Net::HTTP'][:active]

    # Disable at runtime
    OutboundHTTPLogger.disable_patch('net_http')

    status = OutboundHTTPLogger.patch_status

    refute status['Net::HTTP'][:enabled]
    assert status['Net::HTTP'][:applied] # Still applied
    refute status['Net::HTTP'][:active] # But not active

    # Re-enable at runtime
    OutboundHTTPLogger.enable_patch('net_http')

    status = OutboundHTTPLogger.patch_status

    assert status['Net::HTTP'][:enabled]
    assert status['Net::HTTP'][:applied]
    assert status['Net::HTTP'][:active]
  end

  def test_active_patches_reflects_runtime_changes
    OutboundHTTPLogger.configure do |config|
      config.enabled = true
      config.net_http_patch_enabled = true
      config.faraday_patch_enabled = true
    end

    active = OutboundHTTPLogger.active_patches

    assert_includes active, 'Net::HTTP'
    assert_includes active, 'Faraday'

    # Disable one patch
    OutboundHTTPLogger.disable_patch('net_http')

    active = OutboundHTTPLogger.active_patches

    refute_includes active, 'Net::HTTP'
    assert_includes active, 'Faraday'

    # Re-enable
    OutboundHTTPLogger.enable_patch('net_http')

    active = OutboundHTTPLogger.active_patches

    assert_includes active, 'Net::HTTP'
    assert_includes active, 'Faraday'
  end
end
