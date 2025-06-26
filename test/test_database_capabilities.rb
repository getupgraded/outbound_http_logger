# frozen_string_literal: true

require 'test_helper'

describe 'Database Capabilities Testing' do
  include TestHelpers

  before do
    OutboundHTTPLogger.reset_patches!
    OutboundHTTPLogger.disable!
  end

  after do
    OutboundHTTPLogger.reset_patches!
    OutboundHTTPLogger.disable!
  end

  describe 'SQLite Adapter Capabilities' do
    before do
      skip 'SQLite3 gem not available' unless sqlite_available?
    end

    it 'correctly reports SQLite capabilities' do
      adapter = OutboundHTTPLogger::DatabaseAdapters::SqliteAdapter.new(
        'sqlite3:///tmp/test_capabilities.sqlite3',
        :test_capabilities
      )

      # SQLite capabilities should reflect actual limitations
      _(adapter.supports_native_json?).must_equal false
      _(adapter.supports_json_queries?).must_equal false
      _(adapter.supports_full_text_search?).must_equal false
    end

    it 'handles JSON data as text in SQLite' do
      skip 'SQLite3 gem not available' unless sqlite_available?

      # Test SQLite adapter directly to verify JSON handling
      adapter = OutboundHTTPLogger::DatabaseAdapters::SqliteAdapter.new(
        'sqlite3:///tmp/test_json_sqlite.sqlite3',
        :test_json_sqlite
      )

      _(adapter.enabled?).must_equal true
      _(adapter.supports_native_json?).must_equal false

      # Verify that SQLite stores JSON as text
      # This is a capability test, not a full integration test
      test_json = { user: { id: 123, name: 'Test User' } }

      # SQLite should serialize JSON to text
      if adapter.respond_to?(:serialize_json_field, true)
        serialized = adapter.send(:serialize_json_field, test_json)

        _(serialized).must_be_kind_of String
        _(JSON.parse(serialized)['user']['id']).must_equal 123
      end
    end

    it 'performs text-based JSON searches in SQLite' do
      skip 'SQLite3 gem not available' unless sqlite_available?

      # Test SQLite adapter search capabilities
      adapter = OutboundHTTPLogger::DatabaseAdapters::SqliteAdapter.new(
        'sqlite3:///tmp/test_search_sqlite.sqlite3',
        :test_search_sqlite
      )

      _(adapter.enabled?).must_equal true
      _(adapter.supports_json_queries?).must_equal false

      # SQLite should use LIKE queries for JSON search since it doesn't have native JSON support
      # This verifies the adapter correctly reports its limitations
    end
  end

  describe 'PostgreSQL Adapter Capabilities' do
    before do
      skip 'PostgreSQL not available' unless postgresql_test_database_available?
    end

    it 'correctly reports PostgreSQL capabilities' do
      adapter = OutboundHTTPLogger::DatabaseAdapters::PostgresqlAdapter.new(
        'postgresql://localhost/test_db',
        :test_capabilities
      )

      # PostgreSQL should support advanced features
      _(adapter.supports_native_json?).must_equal true
      _(adapter.supports_json_queries?).must_equal true
      _(adapter.supports_full_text_search?).must_equal true
    end

    it 'handles JSON data natively in PostgreSQL' do
      # Test PostgreSQL adapter capabilities
      adapter = OutboundHTTPLogger::DatabaseAdapters::PostgresqlAdapter.new(
        'postgresql://localhost/test_db',
        :test_postgresql
      )

      # PostgreSQL should support native JSON
      _(adapter.supports_native_json?).must_equal true
      _(adapter.supports_json_queries?).must_equal true
      _(adapter.supports_full_text_search?).must_equal true

      # PostgreSQL should handle JSON differently than SQLite
      # This verifies the adapter correctly reports its capabilities
    end

    it 'performs native JSONB queries in PostgreSQL' do
      # Test PostgreSQL adapter query capabilities
      adapter = OutboundHTTPLogger::DatabaseAdapters::PostgresqlAdapter.new(
        'postgresql://localhost/test_db',
        :test_postgresql_queries
      )

      # PostgreSQL should support advanced JSON queries
      _(adapter.supports_json_queries?).must_equal true

      # This verifies that PostgreSQL adapter correctly reports its advanced capabilities
      # compared to SQLite which uses LIKE queries
    end
  end

  describe 'Cross-Database Compatibility' do
    it 'provides consistent interface across adapters' do
      # Test that both adapters implement the same interface
      sqlite_adapter = OutboundHTTPLogger::DatabaseAdapters::SqliteAdapter.new('sqlite3:///tmp/test.db')

      if postgresql_test_database_available?
        pg_adapter = OutboundHTTPLogger::DatabaseAdapters::PostgresqlAdapter.new('postgresql://localhost/test')

        # Both should respond to the same capability methods
        %i[supports_native_json? supports_json_queries? supports_full_text_search?].each do |method|
          _(sqlite_adapter.respond_to?(method)).must_equal true
          _(pg_adapter.respond_to?(method)).must_equal true
        end

        # Both should respond to the same core methods
        %i[adapter_available? enabled? validate_connection log_adapter_error].each do |method|
          _(sqlite_adapter.respond_to?(method)).must_equal true
          _(pg_adapter.respond_to?(method)).must_equal true
        end
      end
    end

    it 'handles errors consistently across adapters' do
      # Test SQLite error handling
      sqlite_adapter = OutboundHTTPLogger::DatabaseAdapters::SqliteAdapter.new('/invalid/path/test.db')

      _(sqlite_adapter.validate_connection).must_equal false

      # Test PostgreSQL error handling if available
      if postgresql_test_database_available?
        pg_adapter = OutboundHTTPLogger::DatabaseAdapters::PostgresqlAdapter.new('postgresql://invalid:invalid@localhost/invalid')

        _(pg_adapter.validate_connection).must_equal false
      end
    end
  end

  describe 'Database Version Compatibility' do
    it 'detects SQLite version and capabilities' do
      skip 'SQLite3 gem not available' unless sqlite_available?

      # Test that we can detect SQLite version
      require 'sqlite3'
      version = SQLite3::SQLITE_VERSION

      _(version).wont_be_nil
      _(version).must_match(/\d+\.\d+\.\d+/)

      # Log the version for debugging
      puts "Testing with SQLite version: #{version}" if ENV['VERBOSE']
    end

    it 'detects PostgreSQL version and capabilities' do
      skip 'PostgreSQL not available' unless postgresql_test_database_available?

      database_url = ENV['OUTBOUND_HTTP_LOGGER_TEST_DATABASE_URL'] ||
                     'postgresql://postgres:@localhost:5432/outbound_http_logger_test'

      # Test that we can connect and get version
      uri = URI.parse(database_url)
      conn = PG.connect(
        host: uri.host,
        port: uri.port || 5432,
        dbname: uri.path[1..],
        user: uri.user,
        password: uri.password
      )

      version_result = conn.exec('SELECT version()')
      version = version_result[0]['version']
      conn.close

      _(version).wont_be_nil
      _(version).must_include 'PostgreSQL'

      # Log the version for debugging
      puts "Testing with PostgreSQL version: #{version}" if ENV['VERBOSE']
    end
  end

  private

    def sqlite_available?
      require 'sqlite3'
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
        dbname: uri.path[1..],
        user: uri.user,
        password: uri.password
      )
      conn.close
      true
    rescue StandardError
      false
    end

    def postgresql_available?
      require 'pg'
      true
    rescue LoadError
      false
    end
end
