# frozen_string_literal: true

require 'test_helper'
require 'rake'
require 'stringio'

describe 'Rake Tasks Integration' do
  include TestHelpers

  # Helper method to capture stdout/stderr
  def capture_io
    old_stdout = $stdout
    old_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  before do
    # Clear any existing tasks to avoid conflicts
    Rake::Task.clear if Rake::Task.respond_to?(:clear)

    # Load the rake tasks
    load File.expand_path('../../lib/outbound_http_logger/tasks/outbound_http_logger.rake', __dir__)

    # Ensure we have some test data
    with_outbound_http_logging_enabled do
      # Clear existing logs first
      OutboundHTTPLogger::Models::OutboundRequestLog.delete_all

      # Create some test logs with specific timestamps
      # Use specific times to ensure predictable cleanup behavior
      old_time = 3.days.ago
      recent_time = 12.hours.ago
      very_recent_time = 1.hour.ago

      OutboundHTTPLogger::Models::OutboundRequestLog.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users',
        status_code: 200,
        duration_ms: 150.5,
        request_headers: { 'Accept' => 'application/json' },
        response_headers: { 'Content-Type' => 'application/json' },
        created_at: old_time
      )

      OutboundHTTPLogger::Models::OutboundRequestLog.create!(
        http_method: 'POST',
        url: 'https://api.example.com/orders',
        status_code: 500,
        duration_ms: 2500.0,
        duration_seconds: 2.5,
        request_headers: { 'Content-Type' => 'application/json' },
        response_headers: { 'Content-Type' => 'application/json' },
        created_at: recent_time
      )

      OutboundHTTPLogger::Models::OutboundRequestLog.create!(
        http_method: 'GET',
        url: 'https://api.example.com/products',
        status_code: 200,
        duration_ms: 75.2,
        duration_seconds: 0.0752,
        request_headers: { 'Accept' => 'application/json' },
        response_headers: { 'Content-Type' => 'application/json' },
        created_at: very_recent_time
      )

      OutboundHTTPLogger::Models::OutboundRequestLog.create!(
        http_method: 'PUT',
        url: 'https://api.example.com/users/123',
        status_code: 404,
        duration_ms: 300.0,
        duration_seconds: 0.3,
        request_headers: { 'Content-Type' => 'application/json' },
        response_headers: { 'Content-Type' => 'application/json' },
        created_at: very_recent_time
      )
    end
  end

  after do
    # Clean up test data
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all
  end

  it 'loads rake tasks without errors' do
    # Verify that the tasks are loaded
    task_names = Rake::Task.tasks.map(&:name)

    _(task_names).must_include 'outbound_http_logger:analyze'
    _(task_names).must_include 'outbound_http_logger:cleanup'
    _(task_names).must_include 'outbound_http_logger:failed'
    _(task_names).must_include 'outbound_http_logger:slow'
  end

  it 'analyze task provides comprehensive statistics' do
    # Capture output from the analyze task
    output = capture_io do
      Rake::Task['outbound_http_logger:analyze'].execute
    end.first

    # Verify the output contains expected sections
    _(output).must_include '=== OutboundHTTPLogger Analysis ==='
    _(output).must_include 'Total outbound request logs: 4'
    _(output).must_include '=== HTTP Method Breakdown ==='
    _(output).must_include 'GET: 2'
    _(output).must_include 'POST: 1'
    _(output).must_include 'PUT: 1'
    _(output).must_include '=== Status Code Breakdown ==='
    _(output).must_include '200 (Success): 2'
    _(output).must_include '404 (Client Error): 1'
    _(output).must_include '500 (Server Error): 1'
    _(output).must_include '=== Performance Metrics ==='
    _(output).must_include 'Average response time:'
    _(output).must_include 'Maximum response time:'
    _(output).must_include 'Slow requests (>1s): 1'
    _(output).must_include '=== Error Analysis ==='
    _(output).must_include 'Total failed requests: 2'
  end

  it 'cleanup task removes old logs' do
    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    _(initial_count).must_equal 4

    # Run cleanup task with 2 day retention (should remove the 3-day-old log)
    capture_io do
      Rake::Task['outbound_http_logger:cleanup'].execute(Rake::TaskArguments.new([:days], [2]))
    end

    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    _(final_count).must_equal 3 # Should have removed 1 log

    # Verify the old log was removed
    old_logs = OutboundHTTPLogger::Models::OutboundRequestLog.where('created_at < ?', 2.days.ago)

    _(old_logs.count).must_equal 0
  end

  it 'cleanup task with default retention (90 days)' do
    initial_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    _(initial_count).must_equal 4

    # Run cleanup task with default retention (should not remove any logs)
    capture_io do
      Rake::Task['outbound_http_logger:cleanup'].execute
    end

    final_count = OutboundHTTPLogger::Models::OutboundRequestLog.count

    _(final_count).must_equal 4 # Should not have removed any logs
  end

  it 'failed task shows recent failed requests' do
    output = capture_io do
      Rake::Task['outbound_http_logger:failed'].execute
    end.first

    _(output).must_include '=== Recent Failed Outbound Requests ==='
    _(output).must_include 'POST https://api.example.com/orders - 500'
    _(output).must_include 'PUT https://api.example.com/users/123 - 404'
  end

  it 'failed task handles no failed requests' do
    # Remove all failed requests
    OutboundHTTPLogger::Models::OutboundRequestLog.where('status_code >= 400').delete_all

    output = capture_io do
      Rake::Task['outbound_http_logger:failed'].execute
    end.first

    _(output).must_include '=== Recent Failed Outbound Requests ==='
    _(output).must_include 'No failed outbound requests found.'
  end

  it 'slow task shows slow requests with default threshold' do
    output = capture_io do
      Rake::Task['outbound_http_logger:slow'].execute
    end.first

    _(output).must_include '=== Slow Outbound Requests (> 1000ms) ==='
    _(output).must_include 'POST https://api.example.com/orders - 500'
  end

  it 'slow task shows slow requests with custom threshold' do
    output = capture_io do
      Rake::Task['outbound_http_logger:slow'].execute(Rake::TaskArguments.new([:threshold], [100]))
    end.first

    _(output).must_include '=== Slow Outbound Requests (> 100ms) ==='
    _(output).must_include 'POST https://api.example.com/orders - 500'
    _(output).must_include 'GET https://api.example.com/users - 200'
    _(output).must_include 'PUT https://api.example.com/users/123 - 404'
  end

  it 'slow task handles no slow requests' do
    output = capture_io do
      Rake::Task['outbound_http_logger:slow'].execute(Rake::TaskArguments.new([:threshold], [5000]))
    end.first

    _(output).must_include '=== Slow Outbound Requests (> 5000ms) ==='
    _(output).must_include 'No slow outbound requests found.'
  end

  it 'tasks handle empty database gracefully' do
    # Clear all logs
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all

    # Test analyze task with no data
    output = capture_io do
      Rake::Task['outbound_http_logger:analyze'].execute
    end.first

    _(output).must_include 'Total outbound request logs: 0'
    _(output).must_include 'No outbound request logs found.'

    # Test failed task with no data
    output = capture_io do
      Rake::Task['outbound_http_logger:failed'].execute
    end.first

    _(output).must_include 'No failed outbound requests found.'

    # Test slow task with no data
    output = capture_io do
      Rake::Task['outbound_http_logger:slow'].execute
    end.first

    _(output).must_include 'No slow outbound requests found.'
  end
end
