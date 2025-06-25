# frozen_string_literal: true

module OutboundHttpLogger
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

        begin
          ensure_connection_and_table
          model_class.count
        rescue StandardError => e
          OutboundHttpLogger.configuration.get_logger&.error("Error counting logs in #{adapter_name}: #{e.class}: #{e.message}")
          0
        end
      end

      # Count logs with specific status
      def count_logs_with_status(status)
        return 0 unless enabled?

        begin
          ensure_connection_and_table
          model_class.where(status_code: status).count
        rescue StandardError => e
          OutboundHttpLogger.configuration.get_logger&.error("Error counting logs with status in #{adapter_name}: #{e.class}: #{e.message}")
          0
        end
      end

      # Count logs for specific URL pattern
      def count_logs_for_url(url_pattern)
        return 0 unless enabled?

        begin
          ensure_connection_and_table
          model_class.where('url LIKE ?', "%#{url_pattern}%").count
        rescue StandardError => e
          OutboundHttpLogger.configuration.get_logger&.error("Error counting logs for URL in #{adapter_name}: #{e.class}: #{e.message}")
          0
        end
      end

      # Clear all logs
      def clear_logs
        return unless enabled?

        begin
          ensure_connection_and_table
          model_class.delete_all
        rescue StandardError => e
          OutboundHttpLogger.configuration.get_logger&.error("Error clearing logs in #{adapter_name}: #{e.class}: #{e.message}")
        end
      end

      # Get all logs
      def all_logs
        return [] unless enabled?

        begin
          ensure_connection_and_table
          model_class.order(created_at: :desc).limit(1000) # Reasonable limit
        rescue StandardError => e
          OutboundHttpLogger.configuration.get_logger&.error("Error fetching logs from #{adapter_name}: #{e.class}: #{e.message}")
          []
        end
      end

      # Log an outbound HTTP request to the database
      def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
        return nil unless enabled?
        return nil unless OutboundHttpLogger.configuration.should_log_url?(url)

        begin
          ensure_connection_and_table

          # Use the model class directly - it will use the correct connection
          model_class.log_request(method, url, request_data, response_data, duration_seconds, options)
        rescue StandardError => e
          OutboundHttpLogger.configuration.get_logger&.error("Error logging request in #{adapter_name}: #{e.class}: #{e.message}")
          nil
        end
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

      private

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
