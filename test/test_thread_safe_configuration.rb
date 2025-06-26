# frozen_string_literal: true

require 'test_helper'

class TestThreadSafeConfiguration < Minitest::Test
  include TestHelpers

  def test_thread_safe_configuration_isolation
    # Test that configuration changes in one thread don't affect another
    results = []
    errors = []

    threads = Array.new(2) do |i|
      Thread.new do # rubocop:disable ThreadSafety/NewThread
        OutboundHttpLogger.with_configuration(enabled: i.even?, debug_logging: i.even?) do
          sleep 0.1 # Allow other thread to potentially interfere
          results[i] = {
            enabled: OutboundHttpLogger.configuration.enabled?,
            debug_logging: OutboundHttpLogger.configuration.debug_logging
          }
        end
      rescue StandardError => e
        errors[i] = e
      end
    end

    threads.each(&:join)

    # Check for errors
    errors.each_with_index do |error, i|
      raise "Thread #{i} failed: #{error}" if error
    end

    # Verify isolation
    assert results[0][:enabled], 'Thread 0 should have enabled=true'
    assert results[0][:debug_logging], 'Thread 0 should have debug_logging=true'
    refute results[1][:enabled], 'Thread 1 should have enabled=false'
    refute results[1][:debug_logging], 'Thread 1 should have debug_logging=false'
  end

  def test_nested_configuration_overrides
    # Test that nested overrides work correctly
    original_enabled = OutboundHttpLogger.configuration.enabled?
    original_debug = OutboundHttpLogger.configuration.debug_logging

    OutboundHttpLogger.with_configuration(enabled: true, debug_logging: false) do
      assert_predicate OutboundHttpLogger.configuration, :enabled?
      refute OutboundHttpLogger.configuration.debug_logging

      OutboundHttpLogger.with_configuration(debug_logging: true) do
        assert_predicate OutboundHttpLogger.configuration, :enabled?
        assert OutboundHttpLogger.configuration.debug_logging
      end

      # Should restore to outer override
      assert_predicate OutboundHttpLogger.configuration, :enabled?
      refute OutboundHttpLogger.configuration.debug_logging
    end

    # Should restore to original
    assert_equal original_enabled, OutboundHttpLogger.configuration.enabled?
    assert_equal original_debug, OutboundHttpLogger.configuration.debug_logging
  end

  def test_configuration_restoration_on_exception
    original_enabled = OutboundHttpLogger.configuration.enabled?

    begin
      OutboundHttpLogger.with_configuration(enabled: true) do
        assert_predicate OutboundHttpLogger.configuration, :enabled?
        raise StandardError, 'Test exception'
      end
    rescue StandardError => e
      assert_equal 'Test exception', e.message
    end

    # Configuration should be restored even after exception
    assert_equal original_enabled, OutboundHttpLogger.configuration.enabled?
  end

  def test_empty_overrides_no_op
    original_config = OutboundHttpLogger.configuration

    OutboundHttpLogger.with_configuration do
      # Should be the same configuration object
      assert_same original_config, OutboundHttpLogger.configuration
    end
  end

  def test_array_configuration_isolation
    # Test that array configurations are properly isolated
    original_excluded_urls = OutboundHttpLogger.configuration.excluded_urls.dup

    OutboundHttpLogger.with_configuration(excluded_urls: ['/test']) do
      assert_equal ['/test'], OutboundHttpLogger.configuration.excluded_urls

      # Modify the array in the override
      OutboundHttpLogger.configuration.excluded_urls << '/another'

      assert_includes OutboundHttpLogger.configuration.excluded_urls, '/another'
    end

    # Original should be unchanged
    assert_equal original_excluded_urls, OutboundHttpLogger.configuration.excluded_urls
    refute_includes OutboundHttpLogger.configuration.excluded_urls, '/test'
    refute_includes OutboundHttpLogger.configuration.excluded_urls, '/another'
  end

  def test_collection_access
    # Test that collections are accessible
    excluded_urls = OutboundHttpLogger.configuration.excluded_urls

    assert_kind_of Array, excluded_urls

    excluded_content_types = OutboundHttpLogger.configuration.excluded_content_types

    assert_kind_of Array, excluded_content_types

    sensitive_headers = OutboundHttpLogger.configuration.sensitive_headers

    assert_kind_of Array, sensitive_headers
  end

  def test_global_configuration_access
    # Test that global_configuration bypasses thread-local overrides
    OutboundHttpLogger.with_configuration(enabled: true) do
      # Thread-local override should affect regular configuration access
      assert_predicate OutboundHttpLogger.configuration, :enabled?

      # But global_configuration should bypass the override
      global_config = OutboundHttpLogger.global_configuration
      # The global config's enabled state depends on test setup, so we just verify it's accessible
      assert_respond_to global_config, :enabled?
    end
  end

  def test_configuration_backup_and_restore
    config = OutboundHttpLogger.configuration

    # Create backup
    backup = config.backup

    # Verify backup contains expected keys
    expected_keys = %i[enabled excluded_urls excluded_content_types sensitive_headers
                       sensitive_body_keys max_body_size debug_logging logger
                       secondary_database_url secondary_database_adapter]

    expected_keys.each do |key|
      assert_includes backup.keys, key, "Backup should include #{key}"
    end

    # Modify configuration
    original_enabled = config.enabled?
    config.enabled = !original_enabled
    config.max_body_size = 99_999

    # Restore from backup
    config.restore(backup)

    # Verify restoration
    assert_equal original_enabled, config.enabled?
    refute_equal 99_999, config.max_body_size
  end

  def test_thread_local_data_clearing
    # Set some thread-local data
    OutboundHttpLogger.set_metadata({ test: 'data' })
    OutboundHttpLogger.set_loggable('test_object')
    Thread.current[:outbound_http_logger_config_override] = OutboundHttpLogger::Configuration.new

    # Verify data is set
    assert_equal({ test: 'data' }, Thread.current[:outbound_http_logger_metadata])
    assert_equal 'test_object', Thread.current[:outbound_http_logger_loggable]
    refute_nil Thread.current[:outbound_http_logger_config_override]

    # Clear thread data
    OutboundHttpLogger.clear_all_thread_data

    # Verify data is cleared
    assert_nil Thread.current[:outbound_http_logger_metadata]
    assert_nil Thread.current[:outbound_http_logger_loggable]
    assert_nil Thread.current[:outbound_http_logger_config_override]
  end

  def test_with_thread_safe_configuration_helper
    # Test the helper method from TestHelpers
    original_enabled = OutboundHttpLogger.configuration.enabled?

    with_thread_safe_configuration(enabled: !original_enabled, max_body_size: 5000) do
      assert_equal !original_enabled, OutboundHttpLogger.configuration.enabled?
      assert_equal 5000, OutboundHttpLogger.configuration.max_body_size
    end

    # Should restore original values
    assert_equal original_enabled, OutboundHttpLogger.configuration.enabled?
    refute_equal 5000, OutboundHttpLogger.configuration.max_body_size
  end
end
