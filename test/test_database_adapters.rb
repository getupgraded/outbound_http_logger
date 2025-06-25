# frozen_string_literal: true

require "test_helper"
require "outbound_http_logger/test"
require "minitest/autorun"

class TestDatabaseAdapters < Minitest::Test
  def setup
    # Ensure clean state
    OutboundHttpLogger::Test.reset!
    # Enable OutboundHttpLogger globally for tests
    OutboundHttpLogger.enable!
  end

  def teardown
    # Clean up after each test
    OutboundHttpLogger::Test.clear_logs! if OutboundHttpLogger::Test.enabled?
    OutboundHttpLogger::Test.reset!
    OutboundHttpLogger.disable!
  end

  def test_sqlite_adapter_creation
    adapter = OutboundHttpLogger::DatabaseAdapters::SqliteAdapter.new(
      'sqlite3:///tmp/test_outbound.sqlite3',
      :test_connection
    )

    assert_equal 'sqlite3:///tmp/test_outbound.sqlite3', adapter.database_url
    assert_equal :test_connection, adapter.connection_name
    assert adapter.adapter_available?, 'SQLite adapter should be available'
  end

  def test_sqlite_adapter_logging
    skip 'SQLite3 gem not available' unless sqlite_available?

    OutboundHttpLogger::Test.configure(
      database_url: 'sqlite3:///tmp/test_outbound_adapter.sqlite3',
      adapter: :sqlite
    )
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!

    # Log a request through the adapter
    adapter = OutboundHttpLogger::Test.instance_variable_get(:@test_adapter)

    # Debug: check if adapter is enabled
    assert adapter.enabled?, "Adapter should be enabled"
    assert OutboundHttpLogger.enabled?, "OutboundHttpLogger should be enabled"

    log_entry = adapter.log_request(
      :get,
      'https://api.example.com/users',
      { headers: { 'Authorization' => 'Bearer token' }, body: '{"query": "test"}' },
      { status_code: 200, headers: { 'Content-Type' => 'application/json' }, body: '{"users": []}' },
      0.5
    )

    refute_nil log_entry
    assert_equal 'GET', log_entry.http_method
    assert_equal 'https://api.example.com/users', log_entry.url
    assert_equal 200, log_entry.status_code
    assert_equal 500.0, log_entry.duration_ms

    # Test counting
    assert_equal 1, OutboundHttpLogger::Test.logs_count
  end

  def test_sqlite_adapter_json_queries
    skip 'SQLite3 gem not available' unless sqlite_available?

    OutboundHttpLogger::Test.configure(adapter: :sqlite)
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!

    # Log a request with JSON data through the adapter
    adapter = OutboundHttpLogger::Test.instance_variable_get(:@test_adapter)
    log_entry = adapter.log_request(
      :post,
      'https://api.example.com/create',
      { body: { name: 'test', type: 'user' } },
      { status_code: 201, body: { id: 123, status: 'created' } },
      0.3
    )

    refute_nil log_entry
    model_class = adapter.model_class

    # Debug: Check what was actually stored
    puts "Request body: #{log_entry.request_body.inspect}"
    puts "Response body: #{log_entry.response_body.inspect}"

    # Test JSON queries (these methods should be public now)
    # For SQLite, the JSON is stored as text, so we need to use the correct query format
    logs_with_name = model_class.with_request_containing('name', 'test')
    assert_equal 1, logs_with_name.count, "Should find log with name='test' in request body"

    logs_with_status = model_class.with_response_containing('status', 'created')
    assert_equal 1, logs_with_status.count, "Should find log with status='created' in response body"
  end

  def test_postgresql_adapter_creation
    adapter = OutboundHttpLogger::DatabaseAdapters::PostgresqlAdapter.new(
      'postgresql://localhost/test_db',
      :test_connection
    )

    assert_equal 'postgresql://localhost/test_db', adapter.database_url
    assert_equal :test_connection, adapter.connection_name
  end

  def test_postgresql_adapter_logging
    skip 'PostgreSQL not available' unless postgresql_test_database_available?

    database_url = ENV['OUTBOUND_HTTP_LOGGER_TEST_DATABASE_URL'] ||
                   'postgresql://postgres:@localhost:5432/outbound_http_logger_test'

    OutboundHttpLogger::Test.configure(
      database_url: database_url,
      adapter: :postgresql
    )
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!

    # Log a request through the adapter
    adapter = OutboundHttpLogger::Test.instance_variable_get(:@test_adapter)
    log_entry = adapter.log_request(
      :post,
      'https://api.example.com/webhook',
      { headers: { 'Content-Type' => 'application/json' }, body: { event: 'user.created', data: { id: 456 } } },
      { status_code: 202, headers: { 'X-Request-ID' => 'req-123' }, body: { received: true } },
      0.8
    )

    refute_nil log_entry
    assert_equal 'POST', log_entry.http_method
    assert_equal 'https://api.example.com/webhook', log_entry.url
    assert_equal 202, log_entry.status_code
    assert_equal 800.0, log_entry.duration_ms

    # Test counting
    assert_equal 1, OutboundHttpLogger::Test.logs_count

    # Test JSON storage format for PostgreSQL
    if postgresql_available?
      # For PostgreSQL, JSON should be stored as objects, not strings
      if log_entry.class.using_jsonb?
        # Check raw storage - should be Hash objects for JSONB
        assert_kind_of Hash, log_entry.read_attribute(:request_body)
        assert_kind_of Hash, log_entry.read_attribute(:response_body)
        assert_equal 456, log_entry.read_attribute(:request_body)['data']['id']
        assert_equal true, log_entry.read_attribute(:response_body)['received']
      end
    end
  end

  def test_adapter_error_handling
    skip 'SQLite3 gem not available' unless sqlite_available?

    # Test that logging gracefully handles errors without breaking
    OutboundHttpLogger::Test.configure(adapter: :sqlite)
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!

    adapter = OutboundHttpLogger::Test.instance_variable_get(:@test_adapter)

    # Test that the adapter doesn't raise exceptions even with problematic data
    # This should succeed since SQLite can handle binary data
    log_entry = nil
    begin
      log_entry = adapter.log_request(
        :get,
        'https://api.example.com/test',
        { body: "\x00\x01\x02" }, # Binary data
        { status_code: 200 },
        0.1
      )
      # The log should be created successfully
      refute_nil log_entry
    rescue => e
      flunk "Expected no exception, but got: #{e.class}: #{e.message}"
    end
  end

  def test_unsupported_adapter
    assert_raises(ArgumentError) do
      OutboundHttpLogger::Test.configure(adapter: :unsupported)
    end
  end

  def test_test_utilities_configuration
    skip 'SQLite3 gem not available' unless sqlite_available?

    OutboundHttpLogger::Test.configure(
      database_url: ':memory:',
      adapter: :sqlite
    )

    OutboundHttpLogger::Test.enable!
    assert OutboundHttpLogger::Test.enabled?

    OutboundHttpLogger::Test.disable!
    refute OutboundHttpLogger::Test.enabled?
  end

  def test_test_utilities_log_counting
    skip 'SQLite3 gem not available' unless sqlite_available?

    OutboundHttpLogger::Test.configure(adapter: :sqlite)
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!

    # Log a test request directly through the adapter
    adapter = OutboundHttpLogger::Test.instance_variable_get(:@test_adapter)
    log_entry = adapter.log_request(
      :get,
      'https://api.example.com/test',
      {},
      { status_code: 200 },
      0.1
    )

    refute_nil log_entry
    assert_equal 1, OutboundHttpLogger::Test.logs_count

    analysis = OutboundHttpLogger::Test.analyze
    assert_equal 1, analysis[:total]
    assert_equal 1, analysis[:successful]
    assert_equal 100.0, analysis[:success_rate]
  end

  def test_postgresql_adapter_json_conversion
    skip 'PostgreSQL not available' unless postgresql_test_database_available?

    database_url = ENV['OUTBOUND_HTTP_LOGGER_TEST_DATABASE_URL'] ||
                   'postgresql://postgres:@localhost:5432/outbound_http_logger_test'

    OutboundHttpLogger::Test.configure(
      database_url: database_url,
      adapter: :postgresql
    )
    OutboundHttpLogger::Test.enable!
    OutboundHttpLogger::Test.clear_logs!

    # Test that the PostgreSQL adapter properly converts JSON strings to objects
    adapter = OutboundHttpLogger::Test.instance_variable_get(:@test_adapter)

    # Test the prepare_json_data_for_postgresql method directly
    test_data = {
      request_headers: { "Content-Type" => "application/json" },
      response_headers: { "Accept" => "application/json" },
      request_body: '{"name": "test", "type": "user"}',
      response_body: '{"id": 123, "status": "created"}',
      metadata: { "action" => "test" }
    }

    model_class = adapter.model_class
    optimized_data = model_class.send(:prepare_json_data_for_postgresql, test_data)

    # Headers and metadata should remain as objects
    assert_kind_of Hash, optimized_data[:request_headers]
    assert_kind_of Hash, optimized_data[:response_headers]
    assert_kind_of Hash, optimized_data[:metadata]

    # JSON string bodies should be converted to objects
    assert_kind_of Hash, optimized_data[:request_body]
    assert_kind_of Hash, optimized_data[:response_body]
    assert_equal "test", optimized_data[:request_body]["name"]
    assert_equal "user", optimized_data[:request_body]["type"]
    assert_equal 123, optimized_data[:response_body]["id"]
    assert_equal "created", optimized_data[:response_body]["status"]
  end

  def test_configuration_backup_restore
    skip 'SQLite3 gem not available' unless sqlite_available?

    # Backup original configuration
    backup = OutboundHttpLogger::Test.backup_configuration

    # Modify configuration
    OutboundHttpLogger::Test.with_configuration(enabled: false) do
      refute OutboundHttpLogger.enabled?
    end

    # Configuration should be restored after block
    OutboundHttpLogger::Test.restore_configuration(backup)
  end

  private

    def sqlite_available?
      require 'sqlite3'
      true
    rescue LoadError
      false
    end

    def postgresql_available?
      require 'pg'
      true
    rescue LoadError
      false
    end

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
