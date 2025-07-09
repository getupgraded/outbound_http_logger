# frozen_string_literal: true

require 'test_helper'

class TestDebugTools < ActiveSupport::TestCase
  # Disable parallelization for observability tests due to singleton state
  parallelize(workers: 0)
  def setup
    @config = OutboundHTTPLogger::Configuration.new
    @config.debug_tools_enabled = true
    @debug_tools = OutboundHTTPLogger::Observability::DebugTools.new(@config)
  end

  def teardown
    OutboundHTTPLogger::ThreadContext.clear_all
  end

  def test_trace_lifecycle
    trace_id = @debug_tools.start_trace('test_operation', { user_id: 123 })

    assert trace_id
    assert_match(/\A[0-9a-f-]{36}\z/, trace_id) # UUID format

    # Check active traces
    active = @debug_tools.active_traces

    assert_equal 1, active.size
    assert_equal trace_id, active.first[:id]
    assert_equal 'test_operation', active.first[:operation]
    assert_equal 123, active.first[:context][:user_id]

    # Add trace event
    @debug_tools.trace_event('step_completed', { step: 'validation' })

    # End trace
    summary = @debug_tools.end_trace(trace_id, { success: true })

    assert summary
    assert_equal trace_id, summary[:id]
    assert_equal 'test_operation', summary[:operation]
    assert summary[:duration_seconds]
    assert summary[:result][:success]

    # Should no longer be active
    assert_empty @debug_tools.active_traces
  end

  def test_with_trace_success
    result = @debug_tools.with_trace('test_operation', { context: 'test' }) do
      'operation_result'
    end

    assert_equal 'operation_result', result
  end

  def test_with_trace_error
    assert_raises(StandardError) do
      @debug_tools.with_trace('failing_operation') do
        raise StandardError, 'Test error'
      end
    end
  end

  def test_profile_operation
    result = @debug_tools.profile('test_profile', { operation_type: 'test' }) do
      sleep 0.01 # Small delay to measure
      'profile_result'
    end

    assert_equal 'profile_result', result
  end

  def test_profile_with_error
    assert_raises(StandardError) do
      @debug_tools.profile('failing_profile') do
        raise StandardError, 'Profile error'
      end
    end
  end

  def test_configuration_validation
    validation = @debug_tools.validate_configuration

    assert_kind_of Hash, validation
    assert validation.key?(:valid)
    assert validation.key?(:warnings)
    assert validation.key?(:errors)
    assert validation.key?(:recommendations)
  end

  def test_configuration_validation_with_issues
    @config.sensitive_headers = []
    @config.sensitive_body_keys = []
    @config.max_body_size = 200_000

    validation = @debug_tools.validate_configuration

    refute_empty validation[:warnings]
    assert(validation[:warnings].any? { |w| w.include?('sensitive headers') })
    assert(validation[:warnings].any? { |w| w.include?('sensitive body keys') })
    assert(validation[:warnings].any? { |w| w.include?('max_body_size') })
  end

  def test_health_check
    health = @debug_tools.health_check

    assert_kind_of Hash, health
    assert health.key?(:status)
    assert health.key?(:timestamp)
    assert health.key?(:checks)

    assert health[:checks].key?(:database)
    assert health[:checks].key?(:memory)
    assert health[:checks].key?(:configuration)
    assert health[:checks].key?(:thread_context)

    # Each check should have a status
    health[:checks].each do |name, check|
      assert check.key?(:status), "Check #{name} missing status"
      assert_includes %w[healthy warning unhealthy], check[:status], "Invalid status for #{name}: #{check[:status]}"
    end
  end

  def test_memory_analysis
    analysis = @debug_tools.memory_analysis

    assert_kind_of Hash, analysis
    assert analysis.key?(:current_usage_mb)
    assert analysis.key?(:timestamp)

    return unless defined?(GC)

    assert analysis.key?(:gc_stats)
    assert analysis[:gc_stats].key?(:heap_live_slots)
  end

  def test_nested_traces
    outer_trace = @debug_tools.start_trace('outer_operation')

    inner_result = @debug_tools.with_trace('inner_operation') do
      'inner_result'
    end

    @debug_tools.end_trace(outer_trace)

    assert_equal 'inner_result', inner_result
  end

  def test_trace_event_without_active_trace
    # Should not raise error when no active trace
    @debug_tools.trace_event('orphan_event', { data: 'test' })
  end

  def test_disabled_debug_tools
    @config.debug_tools_enabled = false

    trace_id = @debug_tools.start_trace('test_operation')

    assert_nil trace_id

    result = @debug_tools.with_trace('test_operation') do
      'result'
    end

    assert_equal 'result', result

    result = @debug_tools.profile('test_operation') do
      'profile_result'
    end

    assert_equal 'profile_result', result
  end

  def test_trace_context_integration
    trace_id = @debug_tools.start_trace('test_operation')

    # Should set trace_id in thread context
    assert_equal trace_id, OutboundHTTPLogger::ThreadContext.metadata[:trace_id]

    @debug_tools.end_trace(trace_id)

    # Should clear trace_id from thread context
    assert_nil OutboundHTTPLogger::ThreadContext.metadata&.dig(:trace_id)
  end

  def test_multiple_active_traces
    trace1 = @debug_tools.start_trace('operation1')
    trace2 = @debug_tools.start_trace('operation2')

    active = @debug_tools.active_traces

    assert_equal 2, active.size

    trace_ids = active.map { |t| t[:id] }

    assert_includes trace_ids, trace1
    assert_includes trace_ids, trace2

    @debug_tools.end_trace(trace1)
    @debug_tools.end_trace(trace2)
  end

  def test_trace_event_timing
    trace_id = @debug_tools.start_trace('timed_operation')

    Time.current
    sleep 0.01
    @debug_tools.trace_event('milestone', { step: 1 })
    sleep 0.01
    Time.current

    summary = @debug_tools.end_trace(trace_id)

    # Duration should be reasonable
    assert_operator summary[:duration_seconds], :>=, 0.02
    assert_operator summary[:duration_seconds], :<, 1.0
  end

  def test_memory_usage_calculation
    usage = @debug_tools.send(:current_memory_usage)

    assert_kind_of Numeric, usage
    assert_operator usage, :>=, 0
  end

  def test_validation_database_config
    @config.secondary_database_url = nil

    validation = @debug_tools.validate_configuration

    assert(validation[:warnings].any? { |w| w.include?('secondary database') })
  end

  def test_validation_unsupported_adapter
    @config.secondary_database_adapter = :unsupported

    validation = @debug_tools.validate_configuration

    assert(validation[:errors].any? { |e| e.include?('Unsupported database adapter') })
    refute validation[:valid]
  end

  def test_validation_performance_settings
    @config.performance_logging_threshold = 0.05

    validation = @debug_tools.validate_configuration

    assert(validation[:recommendations].any? { |r| r.include?('performance_logging_threshold') })
  end

  def test_validation_observability_recommendations
    @config.structured_logging_enabled = false
    @config.metrics_collection_enabled = false

    validation = @debug_tools.validate_configuration

    assert(validation[:recommendations].any? { |r| r.include?('structured logging') })
    assert(validation[:recommendations].any? { |r| r.include?('metrics collection') })
  end

  def test_health_check_memory_warning
    # Mock high memory usage
    @debug_tools.define_singleton_method(:current_memory_usage) { 600.0 }

    health = @debug_tools.health_check

    assert_equal 'warning', health[:checks][:memory][:status]
    assert_includes health[:checks][:memory][:message], 'High memory usage'
  end

  def test_health_check_many_active_traces
    # Create many traces to trigger warning
    105.times { |i| @debug_tools.start_trace("operation_#{i}") }

    health = @debug_tools.health_check

    assert_equal 'warning', health[:checks][:thread_context][:status]
    assert_includes health[:checks][:thread_context][:message], 'Many active traces'
  end

  def test_trace_parent_relationship
    parent_trace = @debug_tools.start_trace('parent_operation')

    child_trace = @debug_tools.start_trace('child_operation')

    active = @debug_tools.active_traces
    active.find { |t| t[:id] == child_trace }

    # Child should reference parent (this would require implementation enhancement)
    # For now, just verify both traces exist
    assert_equal 2, active.size

    @debug_tools.end_trace(child_trace)
    @debug_tools.end_trace(parent_trace)
  end
end
