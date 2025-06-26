# frozen_string_literal: true

require 'test_helper'

class TestStructuredLogger < Minitest::Test
  def setup
    @config = OutboundHTTPLogger::Configuration.new
    @config.structured_logging_enabled = true
    @config.structured_logging_format = :json
    @config.structured_logging_level = :debug
    @config.performance_logging_threshold = 0.1

    @output = StringIO.new
    @underlying_logger = Logger.new(@output)
    @logger = OutboundHTTPLogger::Observability::StructuredLogger.new(@config, @underlying_logger, :json)
  end

  def teardown
    OutboundHTTPLogger::ThreadContext.clear_all
  end

  def test_basic_logging
    @logger.info('Test message', { key: 'value' })

    output = @output.string

    refute_empty output

    parsed = JSON.parse(output.strip)

    assert_equal 'INFO', parsed['level']
    assert_equal 'Test message', parsed['message']
    assert_equal 'value', parsed['key']
    assert parsed['timestamp']
    assert parsed['thread_id']
  end

  def test_log_levels
    @config.structured_logging_level = :warn

    @logger.debug('Debug message')
    @logger.info('Info message')
    @logger.warn('Warn message')

    lines = @output.string.strip.split("\n")

    assert_equal 1, lines.size # Only warn message should be logged

    parsed = JSON.parse(lines.first)

    assert_equal 'WARN', parsed['level']
    assert_equal 'Warn message', parsed['message']
  end

  def test_key_value_format
    @logger = OutboundHTTPLogger::Observability::StructuredLogger.new(@config, @underlying_logger, :key_value)

    @logger.info('Test message', { key: 'value', number: 42 })

    output = @output.string.strip

    assert_includes output, 'level=INFO'
    assert_includes output, 'message=Test message'
    assert_includes output, 'key=value'
    assert_includes output, 'number=42'
  end

  def test_with_context
    @logger.with_context(request_id: 'req-123') do
      @logger.info('Test message')
    end

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'req-123', parsed['request_id']
  end

  def test_performance_logging
    @logger.performance_log('slow_operation', 0.15, { details: 'test' })

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'INFO', parsed['level']
    assert_includes parsed['message'], 'slow_operation'
    assert_in_delta(0.15, parsed['duration_seconds'])
    assert_equal 'test', parsed['details']
  end

  def test_performance_logging_warning_threshold
    @logger.performance_log('very_slow_operation', 0.3, { details: 'test' })

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'WARN', parsed['level']
    assert parsed['performance_warning']
  end

  def test_http_request_logging
    @logger.http_request('GET', 'https://api.example.com/users', 200, 0.5, { user_id: 123 })

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'INFO', parsed['level']
    assert_includes parsed['message'], 'GET'
    assert_includes parsed['message'], 'https://api.example.com/users'
    assert_includes parsed['message'], '200'
    assert_equal 'GET', parsed['method']
    assert_equal 'https://api.example.com/users', parsed['url']
    assert_equal 200, parsed['status_code']
    assert_in_delta(0.5, parsed['duration_seconds'])
    assert parsed['success']
    assert_equal 123, parsed['user_id']
  end

  def test_http_request_error_logging
    @logger.http_request('POST', 'https://api.example.com/users', 500, 1.2)

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'ERROR', parsed['level']
    assert_equal 500, parsed['status_code']
    refute parsed['success']
  end

  def test_database_operation_logging
    @logger.database_operation('insert', 0.05, { table: 'users' })

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'DEBUG', parsed['level']
    assert_includes parsed['message'], 'insert'
    assert_equal 'database', parsed['category']
    assert_equal 'insert', parsed['operation']
    assert_in_delta(0.05, parsed['duration_seconds'])
    assert_equal 'users', parsed['table']
  end

  def test_configuration_change_logging
    @logger.configuration_change('enabled', false, true, { reason: 'test' })

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'INFO', parsed['level']
    assert_includes parsed['message'], 'enabled'
    assert_equal 'configuration', parsed['category']
    assert_equal 'enabled', parsed['setting']
    refute parsed['old_value']
    assert parsed['new_value']
    assert_equal 'test', parsed['reason']
  end

  def test_error_with_context_logging
    error = StandardError.new('Test error')
    error.set_backtrace(%w[line1 line2 line3])

    @logger.error_with_context(error, { operation: 'test_op' })

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'ERROR', parsed['level']
    assert_includes parsed['message'], 'StandardError'
    assert_includes parsed['message'], 'Test error'
    assert_equal 'error', parsed['category']
    assert_equal 'StandardError', parsed['error_class']
    assert_equal 'Test error', parsed['error_message']
    assert_equal 'test_op', parsed['operation']
    assert_kind_of Array, parsed['backtrace']
  end

  def test_url_sanitization
    @logger.http_request('GET', 'https://api.example.com/users?password=secret&token=abc123', 200, 0.1)

    parsed = JSON.parse(@output.string.strip)

    refute_includes parsed['url'], 'secret'
    refute_includes parsed['url'], 'abc123'
    assert_includes parsed['url'], 'https://api.example.com/users'
  end

  def test_disabled_logging
    @config.structured_logging_enabled = false

    @logger.info('Test message')

    assert_empty @output.string
  end

  def test_thread_context_integration
    OutboundHTTPLogger::ThreadContext.metadata = { request_id: 'req-456', user_id: 789 }

    @logger.info('Test message')

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'req-456', parsed['request_id']
    # user_id should not be included as it's not in the metadata request_id key
  end

  def test_gem_version_included
    @logger.info('Test message')

    parsed = JSON.parse(@output.string.strip)

    assert_equal OutboundHTTPLogger::VERSION, parsed['gem_version']
  end

  def test_nested_context_stacking
    @logger.with_context(level1: 'value1') do
      @logger.with_context(level2: 'value2') do
        @logger.info('Nested message')
      end
    end

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'value1', parsed['level1']
    assert_equal 'value2', parsed['level2']
  end

  def test_invalid_url_handling
    @logger.http_request('GET', 'not-a-valid-url', 200, 0.1)

    parsed = JSON.parse(@output.string.strip)

    assert_equal 'not-a-valid-url', parsed['url'] # Should not crash, return original
  end

  def test_fallback_logger_creation
    config = OutboundHTTPLogger::Configuration.new
    config.structured_logging_enabled = true

    # Test with no underlying logger provided
    logger = OutboundHTTPLogger::Observability::StructuredLogger.new(config)

    # Should not raise an error
    assert_respond_to logger, :info
  end
end
