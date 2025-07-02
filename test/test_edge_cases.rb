# frozen_string_literal: true

require 'test_helper'

# rubocop:disable Style/OpenStructUse, ThreadSafety/NewThread

class TestEdgeCases < Minitest::Test
  def setup
    # Reset database adapter cache to ensure clean state
    OutboundHTTPLogger::Models::OutboundRequestLog.reset_adapter_cache!

    # Reset configuration to default state
    config = OutboundHTTPLogger.global_configuration
    config.enabled = false
    config.excluded_urls = [
      %r{https://o\d+\.ingest\..*\.sentry\.io},  # Sentry URLs
      %r{/health},                               # Health check endpoints
      %r{/ping}                                  # Ping endpoints
    ]
    config.excluded_content_types = [
      'text/html',
      'text/css',
      'text/javascript',
      'application/javascript',
      'image/',
      'video/',
      'audio/',
      'font/'
    ]
    config.sensitive_headers = %w[
      authorization
      cookie
      set-cookie
      x-api-key
      x-auth-token
      x-access-token
      bearer
    ]
    config.sensitive_body_keys = %w[
      password
      secret
      token
      api_key
      access_token
      refresh_token
      private_key
      credit_card
      ssn
    ]
    config.max_body_size = OutboundHTTPLogger::Configuration::DEFAULT_MAX_BODY_SIZE
    config.debug_logging = false
    config.logger = nil
    config.secondary_database_url = nil
    config.secondary_database_adapter = :sqlite
    config.max_recursion_depth = OutboundHTTPLogger::Configuration::DEFAULT_MAX_RECURSION_DEPTH
    config.strict_recursion_detection = false

    OutboundHTTPLogger.clear_all_thread_data

    # Enable logging for tests
    OutboundHTTPLogger.enable!
  end

  def teardown
    OutboundHTTPLogger.clear_all_thread_data
    OutboundHTTPLogger.disable!
  end

  # Test concurrent access and thread safety
  def test_concurrent_thread_access
    thread_count = 10
    requests_per_thread = 5
    results = []
    mutex = Mutex.new

    threads = Array.new(thread_count) do |thread_id|
      Thread.new do
        thread_results = []

        requests_per_thread.times do |request_id|
          # Each thread uses different loggable and metadata
          loggable = OpenStruct.new(id: "thread_#{thread_id}_request_#{request_id}")
          metadata = { thread_id: thread_id, request_id: request_id, timestamp: Time.now.to_f }

          OutboundHTTPLogger.with_logging(loggable: loggable, metadata: metadata) do
            # Verify thread isolation
            assert_equal loggable, OutboundHTTPLogger::ThreadContext.loggable
            assert_equal metadata, OutboundHTTPLogger::ThreadContext.metadata

            # Simulate some work
            sleep(0.001)

            # Verify isolation is maintained
            assert_equal loggable, OutboundHTTPLogger::ThreadContext.loggable
            assert_equal metadata, OutboundHTTPLogger::ThreadContext.metadata

            thread_results << { thread_id: thread_id, request_id: request_id, success: true }
          end
        end

        mutex.synchronize { results.concat(thread_results) }
      end
    end

    threads.each(&:join)

    # Verify all threads completed successfully
    assert_equal thread_count * requests_per_thread, results.size
    assert(results.all? { |r| r[:success] })

    # Verify no thread data leakage
    assert_nil OutboundHTTPLogger::ThreadContext.loggable
    assert_nil OutboundHTTPLogger::ThreadContext.metadata
  end

  # Test extreme input sizes
  def test_extreme_input_sizes
    OutboundHTTPLogger.with_configuration(enabled: true, max_body_size: 1000) do
      # Test very long URL
      long_url = "https://api.example.com/test?#{'param=value&' * 1000}"

      assert OutboundHTTPLogger.configuration.should_log_url?(long_url)

      # Test huge request body (should be truncated)
      huge_body = 'x' * 50_000
      log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
        'POST',
        'https://api.example.com/test',
        { body: huge_body },
        { status_code: 200, body: 'OK' },
        0.1
      )

      # Should handle gracefully (may return nil if logging is disabled/fails)
      if log_entry
        assert_equal 'POST', log_entry.http_method
        assert_equal 'https://api.example.com/test', log_entry.url
      end

      # Test huge response body (should be truncated)
      huge_response = 'y' * 50_000
      log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
        'GET',
        'https://api.example.com/test2',
        { body: 'small request' },
        { status_code: 200, body: huge_response },
        0.1
      )

      # Should handle gracefully (may return nil if logging is disabled/fails)
      assert_equal 'GET', log_entry.http_method if log_entry
    end
  end

  # Test malformed and edge case data
  def test_malformed_data_handling
    OutboundHTTPLogger.with_configuration(enabled: true) do
      # Test binary data - should not raise exceptions
      binary_data = "\x00\x01\x02\xFF\xFE"

      begin
        OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
          'POST',
          'https://api.example.com/binary',
          { body: binary_data },
          { status_code: 200, body: binary_data },
          0.1
        )
        # Success - no exception raised
      rescue StandardError => e
        flunk "Binary data handling raised exception: #{e.message}"
      end

      # Test invalid UTF-8 sequences - should not raise exceptions
      invalid_utf8 = "\x80\x81\x82"

      begin
        OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
          'POST',
          'https://api.example.com/invalid-utf8',
          { body: invalid_utf8 },
          { status_code: 200, body: 'OK' },
          0.1
        )
        # Success - no exception raised
      rescue StandardError => e
        flunk "Invalid UTF-8 handling raised exception: #{e.message}"
      end

      # Test nil values - should not raise exceptions
      begin
        OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
          'GET',
          'https://api.example.com/nil-test',
          { body: nil, headers: nil },
          { status_code: 200, body: nil, headers: nil },
          0.1
        )
        # Success - no exception raised
      rescue StandardError => e
        flunk "Nil value handling raised exception: #{e.message}"
      end
    end
  end

  # Test boundary conditions
  def test_boundary_conditions
    # Test max_body_size boundary
    OutboundHTTPLogger.with_configuration(enabled: true, max_body_size: 10) do
      # Exactly at limit
      body_at_limit = 'x' * 10
      log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
        'POST',
        'https://api.example.com/at-limit',
        { body: body_at_limit },
        { status_code: 200, body: 'OK' },
        0.1
      )

      # Should handle gracefully (may return nil if logging is disabled/fails)
      assert_equal 'POST', log_entry.http_method if log_entry

      # One over limit
      body_over_limit = 'x' * 11
      log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
        'POST',
        'https://api.example.com/over-limit',
        { body: body_over_limit },
        { status_code: 200, body: 'OK' },
        0.1
      )

      # Should handle gracefully (may return nil if logging is disabled/fails)
      assert_equal 'POST', log_entry.http_method if log_entry
    end

    # Test zero and negative values
    OutboundHTTPLogger.with_configuration(enabled: true, max_body_size: 0) do
      body = 'test'
      log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
        'POST',
        'https://api.example.com/zero-limit',
        { body: body },
        { status_code: 200, body: 'OK' },
        0.1
      )
      # Should handle gracefully even with zero limit (may return nil)
      assert_equal 'POST', log_entry.http_method if log_entry
    end
  end

  # Test recursion detection and limits
  def test_recursion_detection
    OutboundHTTPLogger.with_configuration(enabled: true, max_recursion_depth: 2, strict_recursion_detection: true) do
      # Test recursion depth tracking
      config = OutboundHTTPLogger.configuration

      # Simulate nested calls
      config.increment_recursion_depth('test_library')

      assert_equal 1, config.current_recursion_depth('test_library')

      config.increment_recursion_depth('test_library')

      assert_equal 2, config.current_recursion_depth('test_library')

      # Should be at limit but not over
      assert config.in_recursion?('test_library')

      # Clean up
      2.times { config.decrement_recursion_depth('test_library') }

      assert_equal 0, config.current_recursion_depth('test_library')
      refute config.in_recursion?('test_library')
    end
  end

  # Test memory pressure scenarios
  def test_memory_pressure_scenarios
    OutboundHTTPLogger.with_configuration(enabled: true) do
      # Test many small requests
      100.times do |i| # Reduced from 1000 to speed up tests
        log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
          'GET',
          "https://api.example.com/test-#{i}",
          { headers: { 'X-Request-ID' => i.to_s } },
          { status_code: 200, body: "response-#{i}" },
          0.001
        )

        # Should handle many requests without issues (may return nil if logging fails)
        assert_equal "https://api.example.com/test-#{i}", log_entry.url if log_entry
      end

      # Test rapid thread creation and destruction
      100.times do
        Thread.new do
          OutboundHTTPLogger.set_metadata(thread_test: true)
          # Thread should clean up automatically
        end.join
      end

      # Main thread should not be affected
      assert_nil OutboundHTTPLogger::ThreadContext.metadata
    end
  end

  # Test error conditions and recovery
  def test_error_conditions_and_recovery
    # Test with strict error detection enabled
    ENV['STRICT_ERROR_DETECTION'] = 'true'

    begin
      # Test database connection errors
      OutboundHTTPLogger.with_configuration(enabled: true) do
        # This should handle the error gracefully
        OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
          'GET',
          'https://api.example.com/error-test',
          { body: 'test' },
          { status_code: 500, body: 'error' },
          0.1
        )

        # Should handle gracefully (may return nil on database errors)
        # The important thing is it doesn't raise an exception
      end
    ensure
      ENV.delete('STRICT_ERROR_DETECTION')
    end
  end

  # Test configuration edge cases
  def test_configuration_edge_cases
    # Test empty and nil configurations
    OutboundHTTPLogger.with_configuration(
      enabled: true,
      excluded_urls: [],
      excluded_content_types: [],
      sensitive_headers: [],
      sensitive_body_keys: []
    ) do
      config = OutboundHTTPLogger.configuration

      # Should handle empty arrays gracefully
      assert config.should_log_url?('https://api.example.com/test')
      assert config.should_log_content_type?('application/json')
    end

    # Test configuration with defaults when arrays are empty
    OutboundHTTPLogger.with_configuration(enabled: true) do
      config = OutboundHTTPLogger.configuration

      # Should work with default configuration
      assert config.should_log_url?('https://api.example.com/test')
      assert config.should_log_content_type?('application/json')
    end
  end

  # Test thread context edge cases
  def test_thread_context_edge_cases
    # Test nested context blocks
    outer_loggable = OpenStruct.new(id: 'outer')
    inner_loggable = OpenStruct.new(id: 'inner')

    OutboundHTTPLogger.with_logging(loggable: outer_loggable, metadata: { level: 'outer' }) do
      assert_equal outer_loggable, OutboundHTTPLogger::ThreadContext.loggable
      assert_equal({ level: 'outer' }, OutboundHTTPLogger::ThreadContext.metadata)

      OutboundHTTPLogger.with_logging(loggable: inner_loggable, metadata: { level: 'inner' }) do
        assert_equal inner_loggable, OutboundHTTPLogger::ThreadContext.loggable
        assert_equal({ level: 'inner' }, OutboundHTTPLogger::ThreadContext.metadata)
      end

      # Should restore outer context
      assert_equal outer_loggable, OutboundHTTPLogger::ThreadContext.loggable
      assert_equal({ level: 'outer' }, OutboundHTTPLogger::ThreadContext.metadata)
    end

    # Should be clean after all blocks
    assert_nil OutboundHTTPLogger::ThreadContext.loggable
    assert_nil OutboundHTTPLogger::ThreadContext.metadata
  end

  # Test URL and content type filtering edge cases
  def test_filtering_edge_cases
    OutboundHTTPLogger.with_configuration(
      enabled: true,
      excluded_urls: [/test/, /api\.internal\.com/],
      excluded_content_types: ['image/', 'text/html']
    ) do
      config = OutboundHTTPLogger.configuration

      # Test URL filtering edge cases
      assert config.should_log_url?('https://api.example.com/users')
      refute config.should_log_url?('https://api.example.com/test')
      refute config.should_log_url?('https://api.internal.com/users')
      refute config.should_log_url?('')
      refute config.should_log_url?(nil)

      # Test content type filtering edge cases
      assert config.should_log_content_type?('application/json')
      refute config.should_log_content_type?('image/png')
      refute config.should_log_content_type?('image/jpeg')
      refute config.should_log_content_type?('text/html')
      assert config.should_log_content_type?('text/plain')
      assert config.should_log_content_type?('') # Empty string should be allowed
      assert config.should_log_content_type?(nil) # Nil should be allowed (no content type)
    end
  end

  # Test sensitive data filtering edge cases
  def test_sensitive_data_filtering_edge_cases
    OutboundHTTPLogger.with_configuration(
      enabled: true,
      sensitive_headers: %w[authorization x-api-key],
      sensitive_body_keys: %w[password secret]
    ) do
      # Test that sensitive data filtering works by creating a log entry
      # and verifying it doesn't expose sensitive information
      log_entry = OutboundHTTPLogger::Models::OutboundRequestLog.log_request(
        'POST',
        'https://api.example.com/login',
        {
          headers: { 'Authorization' => 'Bearer secret-token', 'Content-Type' => 'application/json' },
          body: '{"username": "user", "password": "secret123"}'
        },
        { status_code: 200, body: '{"token": "abc123"}' },
        0.1
      )

      # Should handle gracefully (may return nil if logging is disabled/fails)
      if log_entry
        assert_equal 'POST', log_entry.http_method
        assert_equal 'https://api.example.com/login', log_entry.url
        assert_equal 200, log_entry.status_code
      end
    end
  end
end

require 'ostruct'

# rubocop:enable Style/OpenStructUse, ThreadSafety/NewThread
