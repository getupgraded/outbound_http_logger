# frozen_string_literal: true

require 'test_helper'

class TestMetricsCollector < Minitest::Test
  def setup
    @config = OutboundHTTPLogger::Configuration.new
    @config.metrics_collection_enabled = true
    @collector = OutboundHTTPLogger::Observability::MetricsCollector.new(@config)
  end

  def test_counter_increment
    @collector.increment_counter('test_counter', 1, { tag: 'value' })
    @collector.increment_counter('test_counter', 2, { tag: 'value' })

    snapshot = @collector.snapshot

    assert_equal 3, snapshot[:counters]['test_counter{tag:value}']
  end

  def test_counter_without_tags
    @collector.increment_counter('simple_counter', 5)

    snapshot = @collector.snapshot

    assert_equal 5, snapshot[:counters]['simple_counter']
  end

  def test_histogram_recording
    @collector.record_histogram('response_time', 0.1, { endpoint: '/api/users' })
    @collector.record_histogram('response_time', 0.2, { endpoint: '/api/users' })
    @collector.record_histogram('response_time', 0.15, { endpoint: '/api/users' })

    snapshot = @collector.snapshot
    stats = snapshot[:histograms]['response_time{endpoint:/api/users}']

    assert_equal 3, stats[:count]
    assert_in_delta(0.45, stats[:sum])
    assert_in_delta(0.15, stats[:percentiles][0.5]) # median
    assert_in_delta(0.19, stats[:percentiles][0.9])
  end

  def test_gauge_setting
    @collector.set_gauge('memory_usage', 1024, { unit: 'mb' })
    @collector.set_gauge('memory_usage', 2048, { unit: 'mb' })

    snapshot = @collector.snapshot

    assert_equal 2048, snapshot[:gauges]['memory_usage{unit:mb}']
  end

  def test_http_request_recording
    @collector.record_http_request('GET', 'https://api.example.com/users', 200, 0.5)

    snapshot = @collector.snapshot

    # Check basic counter
    assert_equal 1, snapshot[:counters]['http_requests_total{domain:api.example.com,method:GET,status_code:200}']

    # Check status category counter
    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:2xx,domain:api.example.com}']

    # Check duration histogram
    stats = snapshot[:histograms]['http_request_duration_seconds{domain:api.example.com,method:GET}']

    assert_equal 1, stats[:count]
    assert_in_delta(0.5, stats[:sum])
  end

  def test_http_request_with_error
    error = StandardError.new('Connection failed')
    @collector.record_http_request('POST', 'https://api.example.com/users', 500, 1.2, error)

    snapshot = @collector.snapshot

    # Check error counter
    assert_equal 1, snapshot[:counters]['http_request_errors_total{domain:api.example.com,error_class:StandardError,method:POST}']

    # Check status category
    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:5xx,domain:api.example.com}']
  end

  def test_database_operation_recording
    @collector.record_database_operation('insert', 0.05)

    snapshot = @collector.snapshot

    assert_equal 1, snapshot[:counters]['database_operations_total{operation:insert}']

    stats = snapshot[:histograms]['database_operation_duration_seconds{operation:insert}']

    assert_equal 1, stats[:count]
    assert_in_delta(0.05, stats[:sum])
  end

  def test_database_operation_with_error
    error = ActiveRecord::ConnectionNotEstablished.new('No connection')
    @collector.record_database_operation('select', 0.1, error)

    snapshot = @collector.snapshot

    assert_equal 1, snapshot[:counters]['database_operation_errors_total{error_class:ActiveRecord::ConnectionNotEstablished,operation:select}']
  end

  def test_memory_usage_recording
    @collector.record_memory_usage

    snapshot = @collector.snapshot

    # Should have some memory-related gauges
    assert(snapshot[:gauges].keys.any? { |key| key.include?('memory') })
  end

  def test_prometheus_export
    @collector.increment_counter('test_counter', 5, { env: 'test' })
    @collector.record_histogram('test_histogram', 0.1, { type: 'api' })
    @collector.set_gauge('test_gauge', 42, { unit: 'bytes' })

    prometheus_output = @collector.to_prometheus

    assert_includes prometheus_output, 'test_counter{env="test"} 5'
    assert_includes prometheus_output, 'test_histogram_count{type="api"} 1'
    assert_includes prometheus_output, 'test_histogram_sum{type="api"} 0.1'
    assert_includes prometheus_output, 'test_gauge{unit="bytes"} 42'
  end

  def test_snapshot_includes_metadata
    snapshot = @collector.snapshot

    assert snapshot[:uptime_seconds]
    assert snapshot[:collected_at]
    assert_kind_of Hash, snapshot[:counters]
    assert_kind_of Hash, snapshot[:histograms]
    assert_kind_of Hash, snapshot[:gauges]
  end

  def test_histogram_memory_management
    # Add more than 1000 values to test memory management
    1200.times { |i| @collector.record_histogram('test_metric', i * 0.001) }

    snapshot = @collector.snapshot
    stats = snapshot[:histograms]['test_metric']

    # Should be limited to 1000 values
    assert_equal 1000, stats[:count]
  end

  def test_percentile_calculation
    values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    values.each { |v| @collector.record_histogram('test_percentiles', v) }

    snapshot = @collector.snapshot
    stats = snapshot[:histograms]['test_percentiles']

    assert_in_delta(5.5, stats[:percentiles][0.5]) # median
    assert_in_delta 9.1, stats[:percentiles][0.9], 0.01
    assert_in_delta 9.55, stats[:percentiles][0.95], 0.01
    assert_in_delta 9.91, stats[:percentiles][0.99], 0.01
  end

  def test_domain_extraction
    @collector.record_http_request('GET', 'https://api.example.com:8080/path?query=value', 200, 0.1)

    snapshot = @collector.snapshot
    counter_key = snapshot[:counters].keys.find { |k| k.include?('http_requests_total') }

    assert_includes counter_key, 'domain:api.example.com'
  end

  def test_invalid_url_domain_extraction
    @collector.record_http_request('GET', 'not-a-valid-url', 200, 0.1)

    snapshot = @collector.snapshot
    counter_key = snapshot[:counters].keys.find { |k| k.include?('http_requests_total') }

    assert_includes counter_key, 'domain:unknown'
  end

  def test_status_code_categorization
    @collector.record_http_request('GET', 'https://example.com', 200, 0.1)
    @collector.record_http_request('GET', 'https://example.com', 301, 0.1)
    @collector.record_http_request('GET', 'https://example.com', 404, 0.1)
    @collector.record_http_request('GET', 'https://example.com', 500, 0.1)
    @collector.record_http_request('GET', 'https://example.com', 999, 0.1)

    snapshot = @collector.snapshot

    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:2xx,domain:example.com}']
    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:3xx,domain:example.com}']
    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:4xx,domain:example.com}']
    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:5xx,domain:example.com}']
    assert_equal 1, snapshot[:counters]['http_requests_by_status_category{category:unknown,domain:example.com}']
  end

  def test_reset_functionality
    @collector.increment_counter('test_counter', 5)
    @collector.record_histogram('test_histogram', 0.1)
    @collector.set_gauge('test_gauge', 42)

    @collector.reset!

    snapshot = @collector.snapshot

    assert_empty snapshot[:counters]
    assert_empty snapshot[:histograms]
    assert_empty snapshot[:gauges]
  end

  def test_disabled_metrics_collection
    @config.metrics_collection_enabled = false

    @collector.increment_counter('test_counter', 5)
    @collector.record_histogram('test_histogram', 0.1)

    snapshot = @collector.snapshot

    assert_empty snapshot[:counters]
    assert_empty snapshot[:histograms]
  end

  def test_empty_prometheus_when_disabled
    @config.metrics_collection_enabled = false

    prometheus_output = @collector.to_prometheus

    assert_empty prometheus_output
  end

  def test_thread_safety
    threads = []

    10.times do
      threads << Thread.new do # rubocop:disable ThreadSafety/NewThread
        100.times { |_i| @collector.increment_counter('thread_test', 1, { thread: Thread.current.object_id }) }
      end
    end

    threads.each(&:join)

    snapshot = @collector.snapshot
    total_count = snapshot[:counters].values.sum

    assert_equal 1000, total_count
  end

  def test_metric_key_parsing
    @collector.increment_counter('test_metric', 1, { key1: 'value1', key2: 'value2' })

    prometheus_output = @collector.to_prometheus

    # Should have properly formatted tags
    assert_includes prometheus_output, 'test_metric{key1="value1",key2="value2"} 1'
  end
end
