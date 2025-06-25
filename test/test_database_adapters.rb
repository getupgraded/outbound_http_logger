# frozen_string_literal: true

require "test_helper"
require "outbound_http_logger/test"

describe "Database Adapters" do
  before do
    OutboundHttpLogger.enable!
  end

  after do
    OutboundHttpLogger.disable!
  end

  describe "OutboundRequestLog model" do
    it "can create a log entry" do
      log = OutboundHttpLogger::Models::OutboundRequestLog.create!(
        http_method: 'GET',
        url: 'https://api.example.com/test',
        status_code: 200,
        request_headers: { 'User-Agent' => 'Test' },
        response_headers: { 'Content-Type' => 'application/json' },
        duration_ms: 150.5
      )

      _(log.persisted?).must_equal true
      _(log.http_method).must_equal 'GET'
      _(log.url).must_equal 'https://api.example.com/test'
      _(log.status_code).must_equal 200
      _(log.duration_ms).must_equal 150.5
    end

    it "supports scopes" do
      # Create test data
      OutboundHttpLogger::Models::OutboundRequestLog.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users',
        status_code: 200,
        duration_ms: 100.0
      )

      OutboundHttpLogger::Models::OutboundRequestLog.create!(
        http_method: 'POST',
        url: 'https://api.example.com/orders',
        status_code: 500,
        duration_ms: 2000.0
      )

      # Test scopes
      _(OutboundHttpLogger::Models::OutboundRequestLog.successful.count).must_equal 1
      _(OutboundHttpLogger::Models::OutboundRequestLog.failed.count).must_equal 1
      _(OutboundHttpLogger::Models::OutboundRequestLog.with_method('GET').count).must_equal 1
      _(OutboundHttpLogger::Models::OutboundRequestLog.with_status(200).count).must_equal 1
      _(OutboundHttpLogger::Models::OutboundRequestLog.slow(1000).count).must_equal 1
    end

    it "supports search functionality" do
      # Create test data
      OutboundHttpLogger::Models::OutboundRequestLog.create!(
        http_method: 'GET',
        url: 'https://api.example.com/users',
        status_code: 200,
        duration_ms: 100.0
      )

      # Test search
      results = OutboundHttpLogger::Models::OutboundRequestLog.search(
        q: 'example.com',
        status: 200,
        method: 'GET'
      )

      _(results.count).must_equal 1
      _(results.first.url).must_include 'example.com'
    end

    it "calculates statistics correctly" do
      # Create test data
      3.times do |i|
        OutboundHttpLogger::Models::OutboundRequestLog.create!(
          http_method: 'GET',
          url: "https://api.example.com/test#{i}",
          status_code: i == 2 ? 500 : 200,
          duration_ms: 100.0 + (i * 50)
        )
      end

      _(OutboundHttpLogger::Models::OutboundRequestLog.success_rate).must_equal 66.67
      _(OutboundHttpLogger::Models::OutboundRequestLog.average_duration).must_equal 150.0
      _(OutboundHttpLogger::Models::OutboundRequestLog.total_requests).must_equal 3
    end
  end

  describe "Test utilities" do
    it "provides test configuration" do
      OutboundHttpLogger::Test.configure(
        database_url: ':memory:',
        adapter: :sqlite
      )

      OutboundHttpLogger::Test.enable!
      _(OutboundHttpLogger.enabled?).must_equal true

      OutboundHttpLogger::Test.disable!
      _(OutboundHttpLogger.enabled?).must_equal false
    end

    it "provides log counting utilities" do
      OutboundHttpLogger::Test.enable!
      OutboundHttpLogger::Test.clear_logs!

      # Create test logs
      OutboundHttpLogger::Models::OutboundRequestLog.create!(
        http_method: 'GET',
        url: 'https://api.example.com/test',
        status_code: 200,
        duration_ms: 100.0
      )

      _(OutboundHttpLogger::Test.logs_count).must_equal 1
      _(OutboundHttpLogger::Test.logs_with_status(200).count).must_equal 1
      _(OutboundHttpLogger::Test.logs_for_url('example.com').count).must_equal 1

      analysis = OutboundHttpLogger::Test.analyze
      _(analysis[:total]).must_equal 1
      _(analysis[:successful]).must_equal 1
      _(analysis[:success_rate]).must_equal 100.0
    end
  end

  describe "Configuration" do
    it "supports secondary database configuration" do
      config = OutboundHttpLogger.configuration

      # Ensure clean state
      config.clear_secondary_database

      _(config.secondary_database_configured?).must_equal false

      config.configure_secondary_database('sqlite3:///tmp/test.sqlite3')
      _(config.secondary_database_configured?).must_equal true

      config.clear_secondary_database
      _(config.secondary_database_configured?).must_equal false
    end

    it "filters sensitive data" do
      config = OutboundHttpLogger.configuration

      headers = {
        'Authorization' => 'Bearer secret-token',
        'Content-Type' => 'application/json'
      }

      filtered = config.filter_headers(headers)
      _(filtered['Authorization']).must_equal '[FILTERED]'
      _(filtered['Content-Type']).must_equal 'application/json'

      body = '{"username": "john", "password": "secret123"}'
      filtered_body = config.filter_body(body)
      parsed = JSON.parse(filtered_body)
      _(parsed['password']).must_equal '[FILTERED]'
      _(parsed['username']).must_equal 'john'
    end
  end
end
