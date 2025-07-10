# frozen_string_literal: true

# Start SimpleCov before loading any application code
require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'
  add_filter '/bin/'

  add_group 'Core', 'lib/outbound_http_logger.rb'
  add_group 'Configuration', 'lib/outbound_http_logger/configuration.rb'
  add_group 'Patches', 'lib/outbound_http_logger/patches'
  add_group 'Models', 'lib/outbound_http_logger/models'
  add_group 'Loggers', 'lib/outbound_http_logger/loggers'
  add_group 'Utilities', ['lib/outbound_http_logger/error_handling.rb', 'lib/outbound_http_logger/test.rb']

  # Set minimum coverage thresholds (temporarily disabled to see current state)
  # minimum_coverage 70
  # minimum_coverage_by_file 60
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Load environment variables for testing
begin
  require 'dotenv'
  Dotenv.load('.env.test')
rescue LoadError
  # dotenv not available, continue without it
end

require 'etc'
require 'minitest/autorun'
require 'minitest/spec'
require 'minitest/parallel/db'
require 'mocha/minitest'
require 'logger'
require 'stringio'
require 'webmock/minitest'
require 'active_record'

# Load database adapters based on configuration
database_adapter = ENV.fetch('DATABASE_ADAPTER', 'sqlite3')
case database_adapter
when 'sqlite3'
  require 'sqlite3'
when 'postgresql'
  require 'pg'
else
  raise "Unsupported database adapter: #{database_adapter}"
end

require 'outbound_http_logger'

# Set up database for testing based on environment
def setup_test_database
  database_adapter = ENV.fetch('DATABASE_ADAPTER', 'sqlite3')
  database_url = ENV.fetch('DATABASE_URL', nil)

  case database_adapter
  when 'sqlite3'
    # Configure connection pool for thread-based parallel testing
    # Each thread needs its own connection to avoid pool exhaustion
    # Scale pool size with number of workers, with a reasonable minimum
    worker_count = ENV.fetch('PARALLEL_WORKERS', [1, Etc.nprocessors - 1].max).to_i
    pool_size = [worker_count * 3, 15].max # At least 3 connections per worker, minimum 15

    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: database_url || ':memory:',
      pool: pool_size,
      timeout: 15
    )
  when 'postgresql'
    ActiveRecord::Base.establish_connection(database_url || { adapter: 'postgresql',
                                                              host: ENV.fetch('POSTGRES_HOST', 'localhost'),
                                                              port: ENV.fetch('POSTGRES_PORT', '5432'),
                                                              database: ENV.fetch('POSTGRES_DB', 'outbound_http_logger_test'),
                                                              username: ENV.fetch('POSTGRES_USER', 'postgres'),
                                                              password: ENV.fetch('POSTGRES_PASSWORD', nil) })
  else
    raise "Unsupported database adapter: #{database_adapter}"
  end
end

setup_test_database

# Load test utilities
require 'outbound_http_logger/test'

# Create the outbound_request_logs table for testing
# This function is called both at startup and in the parallelize_setup hook
# to ensure the table exists in each worker's database
def ensure_test_table_exists
  return if ActiveRecord::Base.connection.table_exists?(:outbound_request_logs)

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
    add_index :outbound_request_logs, %i[loggable_type loggable_id]
  end
end

# Ensure table exists initially (for non-parallel testing)
ensure_test_table_exists

# Enable parallelization with database isolation using minitest-parallel-db
# This provides proper database isolation for parallel tests using transactions

# Test helper methods
module TestHelpers
  def self.included(base)
    # Add after hook for Minitest::Spec classes
    return unless base.respond_to?(:after)

    base.after do
      perform_isolation_checks_and_cleanup
    end
  end

  def setup
    # Ensure table exists in this worker's database (important for parallel testing)
    ensure_test_table_exists

    # Reset configuration to defaults FIRST
    OutboundHTTPLogger.reset_configuration!

    # Clear all thread-local data BEFORE any operations to prevent interference
    OutboundHTTPLogger.clear_all_thread_data

    # Reset patch application state
    OutboundHTTPLogger.reset_patches!

    # Reset database adapter cache to prevent memoization issues
    OutboundHTTPLogger::Models::OutboundRequestLog.reset_adapter_cache!

    # Clear all logs
    OutboundHTTPLogger::Models::OutboundRequestLog.delete_all

    # Reset WebMock
    WebMock.reset!
    WebMock.disable_net_connect!
  end

  def teardown
    perform_isolation_checks_and_cleanup
  end

  # NOTE: Removed problematic aliases and duplicate self.included method
  # that were causing infinite recursion in setup

  def perform_isolation_checks_and_cleanup
    # Check for leftover thread-local data and configuration changes
    # This helps identify tests that don't clean up properly
    # Enable with: STRICT_TEST_ISOLATION=true
    if ENV['STRICT_TEST_ISOLATION'] == 'true'
      # Check for isolation violations BEFORE cleanup
      # These will raise errors if violations are found
      assert_no_leftover_thread_data!
      assert_configuration_unchanged!
    end

    # Disable logging (this modifies configuration, so check must be above)
    OutboundHTTPLogger.disable!

    # Clear thread-local data
    OutboundHTTPLogger.clear_all_thread_data
  end

  # Check for leftover thread-local data and raise descriptive errors
  # This helps identify tests that don't clean up properly
  def assert_no_leftover_thread_data!
    # Use ThreadContext to get all current thread data
    leftover_data = OutboundHTTPLogger::ThreadContext.backup_current.compact

    return if leftover_data.empty?

    # Build descriptive error message
    error_details = leftover_data.map do |key, value|
      "  #{key}: #{value.inspect}"
    end.join("\n")

    raise <<~ERROR
      Test isolation failure: Leftover thread-local data detected!

      The following thread-local variables were not cleaned up:
      #{error_details}

      This indicates that a test is not properly cleaning up after itself.
      Each test should ensure all thread-local data is cleared in its teardown.

      To fix this:
      1. Add proper cleanup in the test's teardown method
      2. Use OutboundHTTPLogger.clear_thread_data or clear specific variables
      3. Ensure with_configuration blocks properly restore state

      This check helps maintain test isolation and prevents flaky tests.
    ERROR
  end

  # Check if configuration has been changed from defaults
  # This helps identify tests that modify global configuration without cleanup
  def assert_configuration_unchanged!
    current_config = OutboundHTTPLogger.global_configuration
    default_config = OutboundHTTPLogger.create_fresh_configuration

    changes = []

    # Compare key configuration values (skip 'enabled' since tests commonly change this)
    config_checks = {
      excluded_urls: [current_config.excluded_urls, default_config.excluded_urls],
      excluded_content_types: [current_config.excluded_content_types, default_config.excluded_content_types],
      sensitive_headers: [current_config.sensitive_headers, default_config.sensitive_headers],
      sensitive_body_keys: [current_config.sensitive_body_keys, default_config.sensitive_body_keys],
      max_body_size: [current_config.max_body_size, default_config.max_body_size],
      debug_logging: [current_config.debug_logging, default_config.debug_logging],
      logger: [current_config.logger, default_config.logger]
    }

    config_checks.each do |key, (current, default)|
      changes << "  #{key}: #{current.inspect} (expected: #{default.inspect})" unless current == default
    end

    return if changes.empty?

    raise <<~ERROR
      Test isolation failure: Global configuration was modified!

      The following configuration values were changed from defaults:
      #{changes.join("\n")}

      This indicates that a test modified global configuration without proper cleanup.
      Tests should either:
      1. Use OutboundHTTPLogger.with_configuration for temporary changes
      2. Restore configuration in their teardown method
      3. Use test helpers that automatically restore configuration

      This check helps maintain test isolation and prevents configuration leakage.
    ERROR
  end

  def with_outbound_http_logging_enabled(&)
    # Use complete isolation to ensure no configuration or data leakage
    OutboundHTTPLogger.with_isolated_context(enabled: true, logger: Logger.new(StringIO.new), &)
  end

  def assert_request_logged(method, url, status_code = nil)
    logs = OutboundHTTPLogger::Models::OutboundRequestLog.where(
      http_method: method.to_s.upcase,
      url: url
    )

    logs = logs.where(status_code: status_code) if status_code

    assert_predicate logs, :exists?, "Expected request to be logged: #{method.upcase} #{url}"
    logs.first
  end

  def assert_no_request_logged(method = nil, url = nil)
    scope = OutboundHTTPLogger::Models::OutboundRequestLog.all
    scope = scope.where(http_method: method.to_s.upcase) if method
    scope = scope.where(url: url) if url

    assert_equal 0, scope.count, 'Expected no requests to be logged'
  end

  # Thread-safe configuration override for simple attribute changes
  # This is the recommended method for parallel testing
  def with_thread_safe_configuration(**overrides, &)
    OutboundHTTPLogger.with_configuration(**overrides, &)
  end

  # New adapter-based test helpers
  # These provide better isolation and are recommended for new tests

  # Setup test logging with adapter pattern (recommended)
  def setup_outbound_http_logger_test(database_url: nil, adapter: :sqlite)
    OutboundHTTPLogger::Test.configure(database_url: database_url, adapter: adapter)
    OutboundHTTPLogger::Test.enable!
    OutboundHTTPLogger::Test.clear_logs!
  end

  # Teardown test logging with adapter pattern
  def teardown_outbound_http_logger_test
    OutboundHTTPLogger::Test.reset!
  end

  # Backup current configuration state
  def backup_outbound_http_logger_configuration
    OutboundHTTPLogger::Test.backup_configuration
  end

  # Restore configuration from backup
  def restore_outbound_http_logger_configuration(backup)
    OutboundHTTPLogger::Test.restore_configuration(backup)
  end

  # Execute a block with modified configuration, then restore original
  def with_outbound_http_logger_configuration(**, &)
    OutboundHTTPLogger::Test.with_configuration(**, &)
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
    logs = OutboundHTTPLogger::Test.all_logs.select do |log|
      log.http_method == method.to_s.upcase && log.url == url && (status.nil? || log.status_code == status)
    end

    refute_empty logs, "Expected outbound request to be logged: #{method.upcase} #{url}"
    logs.first
  end

  # Assert request count using the adapter pattern
  def assert_outbound_request_count_with_adapter(expected_count, criteria = {})
    actual_count = if criteria.empty?
                     OutboundHTTPLogger::Test.logs_count
                   else
                     OutboundHTTPLogger::Test.logs_matching(criteria).count
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
Minitest::Spec.include(TestHelpers)

# Enable Rails-style parallel testing with proper database isolation
# Rails automatically creates separate databases for each worker (test-database-0, test-database-1, etc.)
# and handles the complexity of parallel test execution

# Configure thread-based parallel testing
# Using threads instead of processes to avoid DRb serialization issues
# Threads share memory space, so no marshaling of objects is required
#
# Performance notes:
# - Default: 4 threads (optimal for SQLite with in-memory database)
# - Override with PARALLEL_WORKERS environment variable
# - Connection pool scales automatically (3 connections per worker, minimum 15)
# - Thread-based approach avoids DRb serialization issues with Proc objects
module ActiveSupport
  class TestCase
    # Use thread-based parallelization to avoid DRb serialization issues
    # Default to 4 workers for optimal performance with SQLite, but allow override
    worker_count = ENV.fetch('PARALLEL_WORKERS', [1, Etc.nprocessors - 2].max).to_i
    parallelize(workers: worker_count, with: :threads)
  end
end
