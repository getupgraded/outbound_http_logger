# frozen_string_literal: true

require 'test_helper'

# Test to catch test isolation issues that could cause interference
describe 'Test Isolation' do
  before do
    # Reset global configuration to defaults
    OutboundHTTPLogger.reset_configuration!

    # Clear all logs
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all
  end

  after do
    # Disable logging
    OutboundHTTPLogger.disable!

    # Clear thread-local data
    OutboundHTTPLogger.clear_thread_data
  end

  it 'starts each test with clean global state' do
    # Verify that global configuration is in expected default state
    config = OutboundHTTPLogger.global_configuration

    _(config.enabled?).must_equal false
    _(config.max_body_size).must_equal 10_000
    _(config.debug_logging).must_equal false

    # Verify no thread-local overrides
    _(Thread.current[:outbound_http_logger_config_override]).must_be_nil
    _(Thread.current[:outbound_http_logger_loggable]).must_be_nil
    _(Thread.current[:outbound_http_logger_metadata]).must_be_nil

    # Verify no recursion state
    _(Thread.current[:outbound_http_logger_depth_faraday]).must_be_nil
    _(Thread.current[:outbound_http_logger_depth_net_http]).must_be_nil
    _(Thread.current[:outbound_http_logger_depth_httparty]).must_be_nil
  end

  it 'properly isolates thread-local configuration changes' do
    # Verify starting state
    _(OutboundHTTPLogger.enabled?).must_equal false

    # Use thread-local configuration
    OutboundHTTPLogger.with_configuration(enabled: true, max_body_size: 5000) do
      _(OutboundHTTPLogger.enabled?).must_equal true
      _(OutboundHTTPLogger.configuration.max_body_size).must_equal 5000

      # Verify global config is unchanged
      _(OutboundHTTPLogger.global_configuration.enabled?).must_equal false
      _(OutboundHTTPLogger.global_configuration.max_body_size).must_equal 10_000
    end

    # Verify state is restored after block
    _(OutboundHTTPLogger.enabled?).must_equal false
    _(OutboundHTTPLogger.configuration.max_body_size).must_equal 10_000
    _(Thread.current[:outbound_http_logger_config_override]).must_be_nil
  end

  it 'detects when global state is modified without proper cleanup' do
    # This test simulates the problem that was causing test interference

    # Verify starting state
    _(OutboundHTTPLogger.enabled?).must_equal false

    # Simulate a test that modifies global state (like the "when logging is disabled" tests)
    OutboundHTTPLogger.disable! # This should be a no-op since already disabled

    _(OutboundHTTPLogger.enabled?).must_equal false

    # Simulate enabling logging globally (which some tests might do)
    OutboundHTTPLogger.enable!

    _(OutboundHTTPLogger.enabled?).must_equal true

    # The after block should clean this up, but let's verify the cleanup works
    # by manually calling the cleanup code
    OutboundHTTPLogger.disable!
    OutboundHTTPLogger.clear_thread_data

    _(OutboundHTTPLogger.enabled?).must_equal false
  end

  it 'ensures patches respect thread-local configuration' do
    # Verify patches check current configuration, not just global

    # Global config disabled
    OutboundHTTPLogger.disable!

    _(OutboundHTTPLogger.global_configuration.enabled?).must_equal false

    # But thread-local config enabled
    OutboundHTTPLogger.with_configuration(enabled: true) do
      config = OutboundHTTPLogger.configuration

      _(config.enabled?).must_equal true

      # This is what patches should check - current config, not global
      _(OutboundHTTPLogger.enabled?).must_equal true
    end

    # Back to global state
    _(OutboundHTTPLogger.enabled?).must_equal false
  end
end
