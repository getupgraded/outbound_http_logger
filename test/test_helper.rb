# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Load environment variables for testing
begin
  require "dotenv"
  Dotenv.load(".env.test")
rescue LoadError
  # dotenv not available, continue without it
end

require "minitest/autorun"
require "minitest/spec"
require "mocha/minitest"
require "webmock/minitest"
require "active_record"

# Load database adapters based on configuration
database_adapter = ENV.fetch("DATABASE_ADAPTER", "sqlite3")
case database_adapter
when "sqlite3"
  require "sqlite3"
when "postgresql"
  require "pg"
else
  raise "Unsupported database adapter: #{database_adapter}"
end

require "outbound_http_logger"

# Set up database for testing based on environment
def setup_test_database
  database_adapter = ENV.fetch("DATABASE_ADAPTER", "sqlite3")
  database_url = ENV["DATABASE_URL"]

  case database_adapter
  when "sqlite3"
    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: database_url || ':memory:'
    )
  when "postgresql"
    if database_url
      ActiveRecord::Base.establish_connection(database_url)
    else
      ActiveRecord::Base.establish_connection(
        adapter: 'postgresql',
        host: ENV.fetch("POSTGRES_HOST", "localhost"),
        port: ENV.fetch("POSTGRES_PORT", "5432"),
        database: ENV.fetch("POSTGRES_DB", "outbound_http_logger_test"),
        username: ENV.fetch("POSTGRES_USER", "postgres"),
        password: ENV["POSTGRES_PASSWORD"]
      )
    end
  else
    raise "Unsupported database adapter: #{database_adapter}"
  end
end

setup_test_database

# Load test utilities
require 'outbound_http_logger/test'

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

  # Thread-safe configuration override for simple attribute changes
  # This is the recommended method for parallel testing
  def with_thread_safe_configuration(**overrides)
    OutboundHttpLogger.with_configuration(**overrides) do
      yield
    end
  end

  # New adapter-based test helpers
  # These provide better isolation and are recommended for new tests

  # Setup test logging with adapter pattern (recommended)
  def setup_outbound_http_logger_test(database_url: nil, adapter: :sqlite)
    OutboundHttpLogger::Test.configure(database_url: database_url, adapter: adapter)
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!
  end

  # Teardown test logging with adapter pattern
  def teardown_outbound_http_logger_test
    OutboundHttpLogger::Test.reset!
  end

  # Backup current configuration state
  def backup_outbound_http_logger_configuration
    OutboundHttpLogger::Test.backup_configuration
  end

  # Restore configuration from backup
  def restore_outbound_http_logger_configuration(backup)
    OutboundHttpLogger::Test.restore_configuration(backup)
  end

  # Execute a block with modified configuration, then restore original
  def with_outbound_http_logger_configuration(**options, &block)
    OutboundHttpLogger::Test.with_configuration(**options, &block)
  end

  # Setup test with isolated configuration (recommended for most tests)
  def setup_outbound_http_logger_test_with_isolation(database_url: nil, adapter: :sqlite, **config_options)
    # Backup original configuration
    @outbound_http_logger_config_backup = backup_outbound_http_logger_configuration

    # Setup test logging
    setup_outbound_http_logger_test(database_url: database_url, adapter: adapter)

    # Apply configuration options if provided
    return if config_options.empty?

    with_outbound_http_logger_configuration(**config_options) do
      # Configuration is applied within this block
    end
  end

  # Teardown test with configuration restoration
  def teardown_outbound_http_logger_test_with_isolation
    teardown_outbound_http_logger_test
    restore_outbound_http_logger_configuration(@outbound_http_logger_config_backup) if @outbound_http_logger_config_backup
    @outbound_http_logger_config_backup = nil
  end

  # Assert that a request was logged using the adapter pattern
  def assert_outbound_request_logged_with_adapter(method, url, status: nil)
    logs = OutboundHttpLogger::Test.all_logs.select do |log|
      log.http_method == method.to_s.upcase && log.url == url && (status.nil? || log.status_code == status)
    end

    assert !logs.empty?, "Expected outbound request to be logged: #{method.upcase} #{url}"
    logs.first
  end

  # Assert request count using the adapter pattern
  def assert_outbound_request_count_with_adapter(expected_count, criteria = {})
    actual_count = if criteria.empty?
                     OutboundHttpLogger::Test.logs_count
                   else
                     OutboundHttpLogger::Test.logs_matching(criteria).count
                   end

    assert_equal expected_count, actual_count, "Expected #{expected_count} outbound requests, got #{actual_count}"
  end

  # Helper to check if PostgreSQL is available for testing
  def postgresql_available?
    require 'pg'
    true
  rescue LoadError
    false
  end

  # Helper to check if PostgreSQL test database is available
  def postgresql_test_database_available?
    return false unless postgresql_available?

    database_url = ENV['OUTBOUND_HTTP_LOGGER_TEST_DATABASE_URL'] ||
                   ENV['DATABASE_URL'] ||
                   'postgresql://postgres:@localhost:5432/outbound_http_logger_test'

    uri = URI.parse(database_url)
    conn = PG.connect(
      host: uri.host,
      port: uri.port || 5432,
      dbname: uri.path[1..], # Remove leading slash
      user: uri.user,
      password: uri.password
    )
    conn.close
    true
  rescue StandardError
    false
  end
end

# Include test helpers in all test classes
Minitest::Test.include(TestHelpers)
