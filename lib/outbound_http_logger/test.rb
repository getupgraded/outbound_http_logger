# frozen_string_literal: true

require 'active_record'

module OutboundHttpLogger
  module Test
    class << self
      # Configure test logging with a specific database
      def configure(database_url: nil, adapter: :sqlite)
        database_url ||= default_test_database_url
        OutboundHttpLogger.configuration.configure_secondary_database(database_url, adapter: adapter)
        setup_test_database
      end

      # Enable test logging
      def enable!
        OutboundHttpLogger.enable!
      end

      # Disable test logging
      def disable!
        OutboundHttpLogger.disable!
      end

      # Reset test configuration
      def reset!
        disable!
        OutboundHttpLogger.configuration.clear_secondary_database
        clear_logs!
      end

      # Clear all test logs
      def clear_logs!
        OutboundHttpLogger::Models::OutboundRequestLog.delete_all
      rescue StandardError => e
        # Ignore errors if table doesn't exist
        OutboundHttpLogger.configuration.get_logger&.debug("OutboundHttpLogger::Test: Error clearing logs: #{e.message}")
      end

      # Count total logs
      def logs_count
        OutboundHttpLogger::Models::OutboundRequestLog.count
      rescue StandardError
        0
      end

      # Get logs with specific status
      def logs_with_status(status)
        OutboundHttpLogger::Models::OutboundRequestLog.with_status(status)
      rescue StandardError
        []
      end

      # Get logs for specific URL pattern
      def logs_for_url(url_pattern)
        OutboundHttpLogger::Models::OutboundRequestLog.where('url LIKE ?', "%#{url_pattern}%")
      rescue StandardError
        []
      end

      # Get all logs
      def all_logs
        OutboundHttpLogger::Models::OutboundRequestLog.all
      rescue StandardError
        []
      end

      # Get logs matching criteria
      def logs_matching(criteria = {})
        OutboundHttpLogger::Models::OutboundRequestLog.search(criteria)
      rescue StandardError
        []
      end

      # Analyze logs and return statistics
      def analyze
        total = logs_count
        return { total: 0, successful: 0, failed: 0, success_rate: 0.0, average_duration: 0.0 } if total.zero?

        successful = OutboundHttpLogger::Models::OutboundRequestLog.successful.count
        failed = OutboundHttpLogger::Models::OutboundRequestLog.failed.count
        success_rate = (successful.to_f / total * 100).round(2)
        average_duration = OutboundHttpLogger::Models::OutboundRequestLog.average(:duration_ms)&.round(2) || 0.0

        {
          total: total,
          successful: successful,
          failed: failed,
          success_rate: success_rate,
          average_duration: average_duration
        }
      rescue StandardError
        { total: 0, successful: 0, failed: 0, success_rate: 0.0, average_duration: 0.0 }
      end

      private

        def default_test_database_url
          'sqlite3:///tmp/test_outbound_requests.sqlite3'
        end

        def setup_test_database
          return unless OutboundHttpLogger.configuration.secondary_database_configured?

          # Create table if it doesn't exist
          begin
            unless OutboundHttpLogger::Models::OutboundRequestLog.table_exists?
              create_test_table
            end
          rescue StandardError => e
            OutboundHttpLogger.configuration.get_logger&.debug("OutboundHttpLogger::Test: Error setting up database: #{e.message}")
          end
        end

        def create_test_table
          connection = OutboundHttpLogger::Models::OutboundRequestLog.connection

          # Create table based on adapter
          if connection.adapter_name == 'PostgreSQL'
            create_postgresql_table(connection)
          else
            create_sqlite_table(connection)
          end
        end

        def create_postgresql_table(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS outbound_request_logs (
              id BIGSERIAL PRIMARY KEY,
              http_method VARCHAR(10) NOT NULL,
              url TEXT NOT NULL,
              status_code INTEGER NOT NULL,
              request_headers JSONB DEFAULT '{}',
              request_body JSONB,
              response_headers JSONB DEFAULT '{}',
              response_body JSONB,
              duration_seconds DECIMAL(10,6),
              duration_ms DECIMAL(10,2),
              loggable_type VARCHAR(255),
              loggable_id BIGINT,
              metadata JSONB DEFAULT '{}',
              created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            )
          SQL

          # Create essential indexes only
          connection.execute("CREATE INDEX IF NOT EXISTS idx_outbound_logs_created_at ON outbound_request_logs (created_at)")
          connection.execute("CREATE INDEX IF NOT EXISTS idx_outbound_logs_loggable ON outbound_request_logs (loggable_type, loggable_id)")
        end

        def create_sqlite_table(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS outbound_request_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              http_method VARCHAR(10) NOT NULL,
              url TEXT NOT NULL,
              status_code INTEGER NOT NULL,
              request_headers TEXT DEFAULT '{}',
              request_body TEXT,
              response_headers TEXT DEFAULT '{}',
              response_body TEXT,
              duration_seconds REAL,
              duration_ms REAL,
              loggable_type VARCHAR(255),
              loggable_id INTEGER,
              metadata TEXT DEFAULT '{}',
              created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
          SQL

          # Create essential indexes only
          connection.execute("CREATE INDEX IF NOT EXISTS idx_outbound_logs_created_at ON outbound_request_logs (created_at)")
          connection.execute("CREATE INDEX IF NOT EXISTS idx_outbound_logs_loggable ON outbound_request_logs (loggable_type, loggable_id)")
        end
    end

    # Test helpers module for inclusion in test classes
    module Helpers
      def setup_outbound_http_logger_test(database_url: nil, adapter: :sqlite)
        OutboundHttpLogger::Test.configure(database_url: database_url, adapter: adapter)
        OutboundHttpLogger::Test.enable!
        OutboundHttpLogger::Test.clear_logs!
      end

      def teardown_outbound_http_logger_test
        OutboundHttpLogger::Test.reset!
      end

      def assert_outbound_request_logged(method, url, status: nil)
        logs = OutboundHttpLogger::Models::OutboundRequestLog.where(
          http_method: method.to_s.upcase,
          url: url
        )

        logs = logs.where(status_code: status) if status

        assert logs.exists?, "Expected outbound request to be logged: #{method.upcase} #{url}"
        logs.first
      end

      def assert_outbound_request_count(expected_count, criteria = {})
        actual_count = if criteria.empty?
                         OutboundHttpLogger::Test.logs_count
                       else
                         OutboundHttpLogger::Test.logs_matching(criteria).count
                       end

        assert_equal expected_count, actual_count, "Expected #{expected_count} outbound requests, got #{actual_count}"
      end

      def assert_outbound_success_rate(expected_rate, tolerance: 0.1)
        analysis = OutboundHttpLogger::Test.analyze
        actual_rate = analysis[:success_rate]

        assert_in_delta expected_rate, actual_rate, tolerance,
                        "Expected success rate of #{expected_rate}%, got #{actual_rate}%"
      end

      # Thread-safe configuration override for simple attribute changes
      # This is the recommended method for parallel testing
      def with_thread_safe_configuration(**overrides)
        OutboundHttpLogger.with_configuration(**overrides) do
          yield
        end
      end
    end
  end
end
