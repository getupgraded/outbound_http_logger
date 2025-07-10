# frozen_string_literal: true

module OutboundHTTPLogger
  module DatabaseAdapters
    # Base adapter for database-specific logging implementations
    class BaseAdapter
      attr_reader :database_url, :connection_name

      def initialize(database_url, connection_name = :outbound_http_logger_secondary)
        @database_url = database_url
        @connection_name = connection_name
      end

      # Establish connection to the secondary database
      def establish_connection
        raise NotImplementedError, 'Subclasses must implement establish_connection'
      end

      # Get the model class for this adapter
      def model_class
        raise NotImplementedError, 'Subclasses must implement model_class'
      end

      # Count logs
      def count_logs
        return 0 unless enabled?

        OutboundHTTPLogger::ErrorHandling.handle_database_error("count logs in #{adapter_name}", default_return: 0) do
          ensure_connection_and_table
          model_class.count
        end
      end

      # Count logs with specific status
      def count_logs_with_status(status)
        return 0 unless enabled?

        OutboundHTTPLogger::ErrorHandling.handle_database_error("count logs with status in #{adapter_name}", default_return: 0) do
          ensure_connection_and_table
          model_class.where(status_code: status).count
        end
      end

      # Count logs for specific URL pattern
      def count_logs_for_url(url_pattern)
        return 0 unless enabled?

        OutboundHTTPLogger::ErrorHandling.handle_database_error("count logs for URL in #{adapter_name}", default_return: 0) do
          ensure_connection_and_table
          model_class.where('url LIKE ?', "%#{url_pattern}%").count
        end
      end

      # Clear all logs
      def clear_logs
        return unless enabled?

        OutboundHTTPLogger::ErrorHandling.handle_database_error("clear logs in #{adapter_name}") do
          ensure_connection_and_table
          model_class.delete_all
        end
      end

      # Get all logs
      def all_logs
        return [] unless enabled?

        OutboundHTTPLogger::ErrorHandling.handle_database_error("fetch logs from #{adapter_name}", default_return: []) do
          ensure_connection_and_table
          model_class.order(created_at: :desc).limit(OutboundHTTPLogger::Configuration::DEFAULT_LOG_FETCH_LIMIT)
        end
      end

      # Log an outbound HTTP request to the database
      def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = nil, options = {})
        return nil unless enabled?
        return nil unless OutboundHTTPLogger.configuration.should_log_url?(url)

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        error = nil

        begin
          result = OutboundHTTPLogger::ErrorHandling.handle_database_error("log request in #{adapter_name}") do
            ensure_connection_and_table

            # Use the model class directly - it will use the correct connection
            model_class.log_request(method, url, request_data, response_data, duration_seconds, options)
          end
        rescue StandardError => e
          error = e
          raise
        ensure
          # Record database operation metrics
          db_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
          record_database_observability('log_request', db_duration, error)
        end

        result
      end

      # Check if this adapter is enabled
      def enabled?
        @database_url.present? && adapter_available?
      end

      # Check if the required gems/adapters are available
      def adapter_available?
        true # Override in subclasses
      end

      # Get adapter name for logging
      def adapter_name
        self.class.name.split('::').last
      end

      # Standardized connection validation
      def validate_connection
        return false unless enabled?

        OutboundHTTPLogger::ErrorHandling.handle_database_error("validate connection for #{adapter_name}", default_return: false) do
          ensure_connection_and_table
          model_class.connection.active?
        end
      end

      # Standardized error logging for adapter-specific operations
      def log_adapter_error(operation, error)
        logger = OutboundHTTPLogger.configuration.get_logger
        return unless logger

        logger.error("OutboundHTTPLogger #{adapter_name}: Failed to #{operation}: #{error.class}: #{error.message}")
      end

      # Database capability detection (override in subclasses to reflect actual capabilities)
      def supports_native_json?
        false # Conservative default - override in subclasses
      end

      def supports_json_queries?
        false # Conservative default - override in subclasses
      end

      def supports_full_text_search?
        false # Conservative default - override in subclasses
      end

      private

        # Record database operation observability data
        # @param operation [String] Database operation name
        # @param duration [Float] Operation duration in seconds
        # @param error [Exception, nil] Error if operation failed
        # @return [void]
        def record_database_observability(operation, duration, error = nil)
          return unless OutboundHTTPLogger.configuration.observability_enabled?

          begin
            OutboundHTTPLogger.observability.record_database_operation(
              "#{adapter_name}.#{operation}",
              duration,
              error
            )
          rescue StandardError => e
            # Don't let observability errors break the database operation
            # Log the error if debug logging is enabled
            config = OutboundHTTPLogger.configuration
            config.logger.error("Database observability error: #{e.message}") if config.debug_logging && config.logger
          end
        end

        # Ensure connection and table exist
        def ensure_connection_and_table
          establish_connection unless connection_established?
          create_table_if_needed
        end

        # Check if connection is established
        def connection_established?
          # For now, assume connection is established if configuration exists
          ActiveRecord::Base.configurations.configurations.any? { |c| c.name == connection_name.to_s }
        rescue StandardError
          false
        end

        # Create table if it doesn't exist
        def create_table_if_needed
          return if model_class.table_exists?

          create_table_sql = build_create_table_sql
          model_class.connection.execute(create_table_sql)
          create_indexes_sql.each do |sql|
            model_class.connection.execute(sql)
          end
        end

        # Build CREATE TABLE SQL - to be implemented by subclasses
        def build_create_table_sql
          raise NotImplementedError, 'Subclasses must implement build_create_table_sql'
        end

        # Build index creation SQL - to be implemented by subclasses
        def create_indexes_sql
          []
        end
    end
  end
end
