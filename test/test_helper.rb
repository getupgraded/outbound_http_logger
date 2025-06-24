# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "minitest/spec"
require "mocha/minitest"
require "webmock/minitest"
require "active_record"
require "sqlite3"

require "outbound_http_logger"

# Set up in-memory SQLite database for testing
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

# Create the outbound_request_logs table
ActiveRecord::Schema.define do
  create_table :outbound_request_logs do |t|
    t.string :http_method, null: false
    t.text :url, null: false
    t.integer :status_code, null: false
    t.json :request_headers
    t.json :response_headers
    t.json :request_body
    t.json :response_body
    t.json :metadata
    t.decimal :duration_seconds, precision: 10, scale: 6
    t.decimal :duration_ms, precision: 10, scale: 2
    t.references :loggable, polymorphic: true, null: true
    # Only created_at needed for append-only logging
    t.timestamp :created_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
  end

  # Essential indexes for append-only logging (minimal set)
  add_index :outbound_request_logs, :created_at
  add_index :outbound_request_logs, [:loggable_type, :loggable_id]
end

# JSON columns are automatically handled in Rails 8.0+

# Test helper methods
module TestHelpers
  def setup
    # Reset configuration to defaults but don't nil it
    config                        = OutboundHttpLogger.configuration
    config.enabled                = false
    config.excluded_urls          = [
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
    config.sensitive_headers = [
      'authorization',
      'cookie',
      'set-cookie',
      'x-api-key',
      'x-auth-token',
      'x-access-token',
      'bearer'
    ]
    config.sensitive_body_keys = [
      'password',
      'secret',
      'token',
      'key',
      'auth',
      'credential',
      'private'
    ]
    config.max_body_size          = 10_000
    config.debug_logging          = false
    config.logger                 = nil
    # Reset logger
    OutboundHttpLogger.instance_variable_set(:@logger, nil)

    # Clear all logs
    OutboundHttpLogger::Models::OutboundRequestLog.delete_all

    # Reset WebMock
    WebMock.reset!
    WebMock.disable_net_connect!
  end

  def teardown
    # Disable logging
    OutboundHttpLogger.disable!

    # Clear thread-local variables
    Thread.current[:outbound_http_logger_in_request]  = false
    Thread.current[:outbound_http_logger_in_faraday]  = false
    Thread.current[:outbound_http_logger_in_httparty] = false
  end

  def with_logging_enabled
    OutboundHttpLogger.enable!
    yield
  ensure
    OutboundHttpLogger.disable!
  end

  def assert_request_logged(method, url, status_code = nil)
    logs = OutboundHttpLogger::Models::OutboundRequestLog.where(
      http_method: method.to_s.upcase,
      url: url
    )

    logs = logs.where(status_code: status_code) if status_code

    assert_predicate logs, :exists?, "Expected request to be logged: #{method.upcase} #{url}"
    logs.first
  end

  def assert_no_request_logged(method = nil, url = nil)
    scope = OutboundHttpLogger::Models::OutboundRequestLog.all
    scope = scope.where(http_method: method.to_s.upcase) if method
    scope = scope.where(url: url) if url

    assert_equal 0, scope.count, "Expected no requests to be logged"
  end
end

# Include test helpers in all test classes
Minitest::Test.include(TestHelpers)
