# frozen_string_literal: true

require "test_helper"

# Test to catch test isolation issues that could cause interference
describe "Test Isolation" do
  before do
    # Reset global configuration to defaults
    OutboundHttpLogger.reset_configuration!

    # Clear all logs
    OutboundHttpLogger::Models::OutboundRequestLog.delete_all
  end

  after do
    # Disable logging
    OutboundHttpLogger.disable!

    # Clear thread-local data
    OutboundHttpLogger.clear_thread_data
  end

  it "starts each test with clean global state" do
    # Verify that global configuration is in expected default state
    config = OutboundHttpLogger.global_configuration
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

  it "properly isolates thread-local configuration changes" do
    # Verify starting state
    _(OutboundHttpLogger.enabled?).must_equal false

    # Use thread-local configuration
    OutboundHttpLogger.with_configuration(enabled: true, max_body_size: 5000) do
      _(OutboundHttpLogger.enabled?).must_equal true
      _(OutboundHttpLogger.configuration.max_body_size).must_equal 5000

      # Verify global config is unchanged
      _(OutboundHttpLogger.global_configuration.enabled?).must_equal false
      _(OutboundHttpLogger.global_configuration.max_body_size).must_equal 10_000
    end

    # Verify state is restored after block
    _(OutboundHttpLogger.enabled?).must_equal false
    _(OutboundHttpLogger.configuration.max_body_size).must_equal 10_000
    _(Thread.current[:outbound_http_logger_config_override]).must_be_nil
  end

  it "detects when global state is modified without proper cleanup" do
    # This test simulates the problem that was causing test interference

    # Verify starting state
    _(OutboundHttpLogger.enabled?).must_equal false

    # Simulate a test that modifies global state (like the "when logging is disabled" tests)
    OutboundHttpLogger.disable!  # This should be a no-op since already disabled
    _(OutboundHttpLogger.enabled?).must_equal false

    # Simulate enabling logging globally (which some tests might do)
    OutboundHttpLogger.enable!
    _(OutboundHttpLogger.enabled?).must_equal true

    # The after block should clean this up, but let's verify the cleanup works
    # by manually calling the cleanup code
    OutboundHttpLogger.disable!
    OutboundHttpLogger.clear_thread_data

    _(OutboundHttpLogger.enabled?).must_equal false
  end

  it "ensures patches respect thread-local configuration" do
    # Verify patches check current configuration, not just global

    # Global config disabled
    OutboundHttpLogger.disable!
    _(OutboundHttpLogger.global_configuration.enabled?).must_equal false

    # But thread-local config enabled
    OutboundHttpLogger.with_configuration(enabled: true) do
      config = OutboundHttpLogger.configuration
      _(config.enabled?).must_equal true

      # This is what patches should check - current config, not global
      _(OutboundHttpLogger.enabled?).must_equal true
    end

    # Back to global state
    _(OutboundHttpLogger.enabled?).must_equal false
  end
end
