# frozen_string_literal: true

require 'test_helper'

class TestObservability < ActiveSupport::TestCase
  # Disable parallelization for observability tests due to singleton state
  parallelize(workers: 0)
  def setup
    # Call super first to let TestHelpers do its setup (including reset_configuration!)
    super

    # Configure observability after the reset
    @config = OutboundHTTPLogger.configuration
    @config.observability_enabled = true
    @config.structured_logging_enabled = true
    @config.metrics_collection_enabled = true
    @config.debug_tools_enabled = true

    # Initialize observability with the current configuration
    OutboundHTTPLogger::Observability.initialize!(@config)
  end

  def teardown
    OutboundHTTPLogger::ThreadContext.clear_all
    OutboundHTTPLogger::Observability.reset_metrics!

    # Call super to let TestHelpers do its teardown
    super
  end

  def test_initialization
    assert OutboundHTTPLogger::Observability.structured_logger
    assert OutboundHTTPLogger::Observability.metrics_collector
    assert OutboundHTTPLogger::Observability.debug_tools
    assert_equal @config, OutboundHTTPLogger::Observability.configuration
  end

  def test_logging_methods
    # Test that all log level methods work
    %i[debug info warn error fatal].each do |level|
      assert_respond_to OutboundHTTPLogger::Observability, level
    end

    # Test basic logging (won't verify output since we don't control the logger)
    OutboundHTTPLogger::Observability.info('Test message', { key: 'value' })
  end

  def test_record_http_request
    OutboundHTTPLogger::Observability.record_http_request(
      'GET',
      'https://api.example.com/users',
      200,
      0.5,
      nil,
      { user_id: 123 }
    )

    # Verify metrics were recorded
    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot

    assert snapshot[:counters]['http_requests_total{domain:api.example.com,method:GET,status_code:200}']
  end

  def test_record_http_request_with_error
    error = StandardError.new('Connection failed')

    OutboundHTTPLogger::Observability.record_http_request(
      'POST',
      'https://api.example.com/users',
      500,
      1.2,
      error
    )

    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot

    assert snapshot[:counters]['http_request_errors_total{domain:api.example.com,error_class:StandardError,method:POST}']
  end

  def test_record_database_operation
    OutboundHTTPLogger::Observability.record_database_operation(
      'insert',
      0.05,
      nil,
      { table: 'users' }
    )

    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot

    assert snapshot[:counters]['database_operations_total{operation:insert}']
  end

  def test_with_observability
    result = OutboundHTTPLogger::Observability.with_observability('test_operation', { context: 'test' }) do
      'operation_result'
    end

    assert_equal 'operation_result', result
  end

  def test_with_context
    result = OutboundHTTPLogger::Observability.with_context(request_id: 'req-123') do
      'context_result'
    end

    assert_equal 'context_result', result
  end

  def test_metrics_snapshot
    OutboundHTTPLogger::Observability.increment_counter('test_counter', 5)

    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot

    assert_kind_of Hash, snapshot
    assert snapshot.key?(:counters)
    assert snapshot.key?(:histograms)
    assert snapshot.key?(:gauges)
    assert_equal 5, snapshot[:counters]['test_counter']
  end

  def test_metrics_prometheus
    OutboundHTTPLogger::Observability.increment_counter('test_counter', 3)

    prometheus = OutboundHTTPLogger::Observability.metrics_prometheus

    assert_kind_of String, prometheus
    assert_includes prometheus, 'test_counter 3'
  end

  def test_health_check
    health = OutboundHTTPLogger::Observability.health_check

    assert_kind_of Hash, health
    assert health.key?(:status)
    assert health.key?(:checks)
  end

  def test_validate_configuration
    validation = OutboundHTTPLogger::Observability.validate_configuration

    assert_kind_of Hash, validation
    assert validation.key?(:valid)
    assert validation.key?(:warnings)
    assert validation.key?(:errors)
  end

  def test_memory_analysis
    analysis = OutboundHTTPLogger::Observability.memory_analysis

    assert_kind_of Hash, analysis
    assert analysis.key?(:current_usage_mb)
  end

  def test_active_traces
    # Ensure we start with no active traces
    initial_traces = OutboundHTTPLogger::Observability.active_traces

    assert_equal 0, initial_traces.size

    trace_id = OutboundHTTPLogger::Observability.start_trace('test_operation')

    traces = OutboundHTTPLogger::Observability.active_traces

    assert_equal 1, traces.size
    assert_equal trace_id, traces.first[:id]

    OutboundHTTPLogger::Observability.end_trace(trace_id)

    # Should be empty again
    final_traces = OutboundHTTPLogger::Observability.active_traces

    assert_equal 0, final_traces.size
  end

  def test_record_memory_usage
    OutboundHTTPLogger::Observability.record_memory_usage

    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot
    # Should have some memory-related gauges (if available on this system)
    # This test just ensures the method doesn't crash
    assert_kind_of Hash, snapshot[:gauges]
  end

  def test_log_configuration_change
    OutboundHTTPLogger::Observability.log_configuration_change(
      'enabled',
      false,
      true,
      { reason: 'test' }
    )

    # Should not raise error
  end

  def test_log_error
    error = StandardError.new('Test error')

    OutboundHTTPLogger::Observability.log_error(error, { operation: 'test' })

    # Should not raise error
  end

  def test_observability_enabled_checks
    assert_predicate OutboundHTTPLogger::Observability, :observability_enabled?
    assert_predicate OutboundHTTPLogger::Observability, :structured_logging_enabled?
    assert_predicate OutboundHTTPLogger::Observability, :metrics_collection_enabled?
    assert_predicate OutboundHTTPLogger::Observability, :debug_tools_enabled?
  end

  def test_observability_disabled
    # Store original configuration
    original_config = OutboundHTTPLogger::Observability.configuration

    # Create a new config with observability disabled
    disabled_config = OutboundHTTPLogger::Configuration.new
    disabled_config.observability_enabled = false
    disabled_config.structured_logging_enabled = false
    disabled_config.metrics_collection_enabled = false
    disabled_config.debug_tools_enabled = false

    OutboundHTTPLogger::Observability.initialize!(disabled_config)

    refute_predicate OutboundHTTPLogger::Observability, :observability_enabled?
    refute_predicate OutboundHTTPLogger::Observability, :structured_logging_enabled?
    refute_predicate OutboundHTTPLogger::Observability, :metrics_collection_enabled?
    refute_predicate OutboundHTTPLogger::Observability, :debug_tools_enabled?

    # Restore original configuration
    OutboundHTTPLogger::Observability.initialize!(original_config) if original_config
  end

  def test_trace_lifecycle
    trace_id = OutboundHTTPLogger::Observability.start_trace('test_operation', { user_id: 123 })

    assert trace_id

    OutboundHTTPLogger::Observability.trace_event('step_completed', { step: 'validation' })

    summary = OutboundHTTPLogger::Observability.end_trace(trace_id, { success: true })

    assert summary
    assert_equal trace_id, summary[:id]
  end

  def test_profile_operation
    result = OutboundHTTPLogger::Observability.profile('test_profile', { type: 'test' }) do
      'profile_result'
    end

    assert_equal 'profile_result', result
  end

  def test_metric_operations
    OutboundHTTPLogger::Observability.increment_counter('test_counter', 2, { env: 'test' })
    OutboundHTTPLogger::Observability.record_histogram('test_histogram', 0.5, { type: 'api' })
    OutboundHTTPLogger::Observability.set_gauge('test_gauge', 100, { unit: 'mb' })

    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot

    assert_equal 2, snapshot[:counters]['test_counter{env:test}']
    assert_equal 1, snapshot[:histograms]['test_histogram{type:api}'][:count]
    assert_equal 100, snapshot[:gauges]['test_gauge{unit:mb}']
  end

  def test_reset_metrics
    OutboundHTTPLogger::Observability.increment_counter('test_counter', 5)

    OutboundHTTPLogger::Observability.reset_metrics!

    snapshot = OutboundHTTPLogger::Observability.metrics_snapshot

    assert_empty snapshot[:counters]
  end

  def test_with_observability_disabled
    @config.observability_enabled = false
    @config.structured_logging_enabled = false
    @config.metrics_collection_enabled = false
    @config.debug_tools_enabled = false

    OutboundHTTPLogger::Observability.initialize!(@config)

    result = OutboundHTTPLogger::Observability.with_observability('test_operation') do
      'result'
    end

    assert_equal 'result', result
  end

  def test_error_handling_in_record_http_request
    # Mock an error in the underlying components
    OutboundHTTPLogger::Observability.metrics_collector.define_singleton_method(:record_http_request) do |*_args|
      raise StandardError, 'Metrics error'
    end

    # Should not raise error, should handle gracefully
    OutboundHTTPLogger::Observability.record_http_request('GET', 'https://example.com', 200, 0.1)
  end

  def test_nil_configuration_handling
    # Test behavior when configuration is nil
    OutboundHTTPLogger::Observability.instance_variable_set(:@configuration, nil)

    refute_predicate OutboundHTTPLogger::Observability, :observability_enabled?
    refute_predicate OutboundHTTPLogger::Observability, :structured_logging_enabled?
    refute_predicate OutboundHTTPLogger::Observability, :metrics_collection_enabled?
    refute_predicate OutboundHTTPLogger::Observability, :debug_tools_enabled?
  end

  def test_uninitialized_components_handling
    # Test behavior when components are not initialized
    OutboundHTTPLogger::Observability.instance_variable_set(:@structured_logger, nil)
    OutboundHTTPLogger::Observability.instance_variable_set(:@metrics_collector, nil)
    OutboundHTTPLogger::Observability.instance_variable_set(:@debug_tools, nil)

    # Should not raise errors
    OutboundHTTPLogger::Observability.info('Test message')

    assert_empty OutboundHTTPLogger::Observability.metrics_snapshot
    assert_equal({ status: 'unknown', message: 'Debug tools not initialized' },
                 OutboundHTTPLogger::Observability.health_check)
  end

  def test_integration_with_main_module
    # Test that the main module can access observability
    OutboundHTTPLogger.configure do |config|
      config.observability_enabled = true
      config.structured_logging_enabled = true
    end

    observability = OutboundHTTPLogger.observability

    assert observability
    assert_respond_to observability, :record_http_request
  end
end
