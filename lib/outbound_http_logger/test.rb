# frozen_string_literal: true

require 'active_record'

module OutboundHTTPLogger
  module Test
    class << self
      # Configure test logging with a separate database
      def configure(database_url: nil, adapter: :sqlite)
        @test_adapter = create_adapter(database_url, adapter)
        @test_adapter&.establish_connection
      end

      # Enable test logging
      def enable!
        configure unless @test_adapter
        @enabled = true
      end

      # Disable test logging
      def disable!
        @enabled = false
      end

      # Check if test logging is enabled
      def enabled?
        @enabled && @test_adapter&.enabled?
      end

      # Reset test configuration
      def reset!
        disable!
        clear_logs!
        @test_adapter = nil
      end

      # Clear all test logs
      def clear_logs!
        return unless enabled?

        @test_adapter.clear_logs
      rescue StandardError => e
        OutboundHTTPLogger.configuration.get_logger&.debug("OutboundHTTPLogger::Test: Error clearing logs: #{e.message}")
      end

      # Count total logs
      def logs_count
        return 0 unless enabled?

        @test_adapter.count_logs
      rescue StandardError
        0
      end

      # Get logs with specific status
      def logs_with_status(status)
        return [] unless enabled?

        @test_adapter.model_class.with_status(status)
      rescue StandardError
        []
      end

      # Get logs for specific URL pattern
      def logs_for_url(url_pattern)
        return [] unless enabled?

        @test_adapter.count_logs_for_url(url_pattern)
      rescue StandardError
        []
      end

      # Get all logs
      def all_logs
        return [] unless enabled?

        @test_adapter.all_logs
      rescue StandardError
        []
      end

      # Get logs matching criteria
      def logs_matching(criteria = {})
        return [] unless enabled?

        @test_adapter.model_class.search(criteria)
      rescue StandardError
        []
      end

      # Log a request directly (for testing)
      def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
        return nil unless enabled?

        @test_adapter.log_request(method, url, request_data, response_data, duration_seconds, options)
      end

      # Analyze logs and return statistics
      def analyze
        return { total: 0, successful: 0, failed: 0, success_rate: 0.0, average_duration: 0.0 } unless enabled?

        total = logs_count
        return { total: 0, successful: 0, failed: 0, success_rate: 0.0, average_duration: 0.0 } if total.zero?

        successful = @test_adapter.model_class.successful.count
        failed = @test_adapter.model_class.failed.count
        success_rate = (successful.to_f / total * 100).round(2)
        average_duration = @test_adapter.model_class.average(:duration_ms)&.round(2) || 0.0

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

      # Get all formatted calls
      def all_calls
        return [] unless enabled?

        @test_adapter.all_logs.map { |log| "#{log.http_method} #{log.url}" }
      rescue StandardError
        []
      end

      # Backup current configuration state
      def backup_configuration
        OutboundHTTPLogger.configuration.backup
      end

      # Restore configuration from backup
      def restore_configuration(backup)
        OutboundHTTPLogger.configuration.restore(backup)
      end

      # Execute a block with modified configuration, then restore original
      def with_configuration(**, &)
        OutboundHTTPLogger.with_configuration(**, &)
      end

      private

        def create_adapter(database_url, adapter_type)
          database_url ||= default_test_database_url(adapter_type)

          case adapter_type.to_sym
          when :sqlite
            require_relative 'database_adapters/sqlite_adapter'
            DatabaseAdapters::SqliteAdapter.new(database_url, :outbound_http_logger_test)
          when :postgresql
            require_relative 'database_adapters/postgresql_adapter'
            DatabaseAdapters::PostgresqlAdapter.new(database_url, :outbound_http_logger_test)
          else
            raise ArgumentError, "Unsupported adapter: #{adapter_type}"
          end
        end

        def default_test_database_url(adapter_type = :sqlite)
          case adapter_type.to_sym
          when :sqlite
            'sqlite3:///tmp/test_outbound_requests.sqlite3'
          when :postgresql
            ENV['OUTBOUND_HTTP_LOGGER_TEST_DATABASE_URL'] || 'postgresql://localhost/outbound_http_logger_test'
          else
            raise ArgumentError, "No default URL for adapter: #{adapter_type}"
          end
        end
    end

    # Test helpers module for inclusion in test classes
    module Helpers
      # Setup test logging
      def setup_outbound_http_logger_test(database_url: nil, adapter: :sqlite)
        OutboundHTTPLogger::Test.configure(database_url: database_url, adapter: adapter)
        OutboundHTTPLogger::Test.enable!
        OutboundHTTPLogger::Test.clear_logs!
      end

      # Teardown test logging
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

      def assert_outbound_request_logged(method, url, status: nil)
        logs = OutboundHTTPLogger::Test.all_logs.select do |log|
          log.http_method == method.to_s.upcase && log.url == url && (status.nil? || log.status_code == status)
        end

        assert !logs.empty?, "Expected outbound request to be logged: #{method.upcase} #{url}"
        logs.first
      end

      def assert_outbound_request_count(expected_count, criteria = {})
        actual_count = if criteria.empty?
                         OutboundHTTPLogger::Test.logs_count
                       else
                         OutboundHTTPLogger::Test.logs_matching(criteria).count
                       end

        assert_equal expected_count, actual_count, "Expected #{expected_count} outbound requests, got #{actual_count}"
      end

      def assert_outbound_success_rate(expected_rate, tolerance: 0.1)
        analysis = OutboundHTTPLogger::Test.analyze
        actual_rate = analysis[:success_rate]

        assert_in_delta expected_rate, actual_rate, tolerance,
                        "Expected success rate of #{expected_rate}%, got #{actual_rate}%"
      end
    end
  end
end
