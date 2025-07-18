# frozen_string_literal: true

require 'fileutils'
require_relative 'base_adapter'

module OutboundHTTPLogger
  module DatabaseAdapters
    class SqliteAdapter < BaseAdapter
      # Check if SQLite3 gem is available
      def adapter_available?
        @adapter_available ||= begin
          require 'sqlite3'
          true
        rescue LoadError
          log_adapter_error('load sqlite3 gem', StandardError.new('SQLite3 gem not available')) if @database_url.present?
          false
        end
      end

      # SQLite capabilities
      def supports_native_json?
        false # SQLite stores JSON as text, not native JSON type
      end

      def supports_json_queries?
        # SQLite 3.38+ has JSON functions, but we use LIKE queries for compatibility
        false
      end

      def supports_full_text_search?
        # SQLite has FTS extensions, but we use basic LIKE queries for simplicity
        false
      end

      # Establish connection to SQLite database
      def establish_connection
        return unless adapter_available?

        # Parse database URL or use as file path
        db_path = parse_database_path

        # Ensure directory exists
        FileUtils.mkdir_p(File.dirname(db_path))

        # Configure the connection for Rails multiple database support
        config = {
          'adapter' => 'sqlite3',
          'database' => db_path,
          'pool' => OutboundHTTPLogger::Configuration::DEFAULT_CONNECTION_POOL_SIZE,
          'timeout' => OutboundHTTPLogger::Configuration::DEFAULT_CONNECTION_TIMEOUT
        }

        # Add to Rails configurations and establish connection
        env_name = defined?(Rails) ? Rails.env : 'test'
        ActiveRecord::Base.configurations.configurations << ActiveRecord::DatabaseConfigurations::HashConfig.new(
          env_name,
          connection_name.to_s,
          config
        )

        # Establish the connection in the connection handler
        ActiveRecord::Base.connection_handler.establish_connection(config, owner_name: connection_name.to_s)

        # Ensure the database file is writable
        File.chmod(0o644, db_path) if File.exist?(db_path)
      end

      # Get the model class for SQLite
      def model_class
        @model_class ||= create_model_class
      end

      private

        def parse_database_path
          if @database_url.start_with?('sqlite3://')
            # Handle sqlite3://path/to/db.sqlite3 format
            @database_url.sub('sqlite3://', '')
          elsif @database_url.start_with?('sqlite://')
            # Handle sqlite://path/to/db.sqlite3 format
            @database_url.sub('sqlite://', '')
          else
            # Treat as direct file path
            @database_url
          end
        end

        def create_model_class
          adapter_connection_name = connection_name

          # Create a named class to avoid "Anonymous class is not allowed" error
          class_name = "SqliteOutboundRequestLog#{adapter_connection_name.to_s.camelize}"

          # Remove existing class if it exists
          OutboundHTTPLogger::DatabaseAdapters.send(:remove_const, class_name) if OutboundHTTPLogger::DatabaseAdapters.const_defined?(class_name)

          # Create the new class that inherits from the main model
          klass = Class.new(OutboundHTTPLogger::Models::OutboundRequestLog) do
            self.table_name = 'outbound_request_logs'

            # Store the connection name for use in connection method
            @adapter_connection_name = adapter_connection_name

            # Override connection to use the secondary database
            def self.connection
              if @adapter_connection_name
                # Use configured named connection - fail explicitly if not available
                ActiveRecord::Base.connection_handler.retrieve_connection(@adapter_connection_name.to_s)
              else
                # Use default connection when explicitly configured to do so
                ActiveRecord::Base.connection
              end
            rescue ActiveRecord::ConnectionNotEstablished => e
              # Don't fall back silently - log the specific issue and re-raise
              Rails.logger&.error "OutboundHTTPLogger: Cannot retrieve connection '#{@adapter_connection_name}': #{e.message}"
              raise
            end

            class << self
              def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
                return nil unless OutboundHTTPLogger.enabled?
                return nil unless OutboundHTTPLogger.configuration.should_log_url?(url)

                # Check content type filtering
                content_type = response_data[:headers]&.[]('content-type') ||
                               response_data[:headers]&.[]('Content-Type')
                return nil unless OutboundHTTPLogger.configuration.should_log_content_type?(content_type)

                # Ensure table exists before logging
                unless table_exists?
                  connection.execute(build_create_table_sql)
                  build_indexes_sql.each { |sql| connection.execute(sql) }
                end

                duration_ms = (duration_seconds * 1000).round(2)

                # Get thread-local metadata and loggable
                thread_metadata = Thread.current[:outbound_http_logger_metadata] || {}
                thread_loggable = Thread.current[:outbound_http_logger_loggable]

                # Merge metadata
                merged_metadata = thread_metadata.merge(request_data[:metadata] || {}).merge(options[:metadata] || {})

                # Prepare log data
                log_data = {
                  http_method: method.to_s.upcase,
                  url: url,
                  status_code: response_data[:status_code] || 0,
                  request_headers: OutboundHTTPLogger.configuration.filter_headers(request_data[:headers] || {}),
                  request_body: OutboundHTTPLogger.configuration.filter_body(request_data[:body]),
                  response_headers: OutboundHTTPLogger.configuration.filter_headers(response_data[:headers] || {}),
                  response_body: OutboundHTTPLogger.configuration.filter_body(response_data[:body]),
                  duration_ms: duration_ms,
                  loggable: request_data[:loggable] || thread_loggable,
                  metadata: merged_metadata
                }

                # For SQLite, ensure JSON fields are properly serialized
                log_data = optimize_for_sqlite(log_data)

                create!(log_data)
              rescue StandardError => e
                # Failsafe: Never let logging errors break the HTTP request
                log_adapter_error('log request', e)
                nil
              end

              # SQLite-specific text search
              def apply_text_search(scope, q, _original_query)
                scope.where(
                  'LOWER(url) LIKE ? OR LOWER(request_body) LIKE ? OR LOWER(response_body) LIKE ?',
                  q, q, q
                )
              end

              # SQLite-specific JSON scopes
              # Note: For SQLite, JSON is stored as text. Due to issues with JSON_EXTRACT
              # and ActiveRecord parameter binding, we use LIKE queries for better compatibility
              def with_response_containing(key, value)
                # Use LIKE query to search for the key-value pair in JSON text
                # Handle both escaped and unescaped JSON formats
                where('response_body LIKE ? OR response_body LIKE ?',
                      "%\"#{key}\":\"#{value}\"%",
                      "%\\\"#{key}\\\":\\\"#{value}\\\"%")
              end

              def with_request_containing(key, value)
                # Use LIKE query to search for the key-value pair in JSON text
                # Handle both escaped and unescaped JSON formats
                where('request_body LIKE ? OR request_body LIKE ?',
                      "%\"#{key}\":\"#{value}\"%",
                      "%\\\"#{key}\\\":\\\"#{value}\\\"%")
              end

              def with_metadata_containing(key, value)
                # Use LIKE query to search for the key-value pair in JSON text
                # Handle both escaped and unescaped JSON formats
                where('metadata LIKE ? OR metadata LIKE ?',
                      "%\"#{key}\":\"#{value}\"%",
                      "%\\\"#{key}\\\":\\\"#{value}\\\"%")
              end

              # SQLite-specific header queries
              def with_response_header(header_name, header_value = nil)
                if header_value
                  where('response_headers LIKE ?', "%\"#{header_name}\":\"#{header_value}\"%")
                else
                  where('response_headers LIKE ?', "%\"#{header_name}\":%")
                end
              end

              def with_request_header(header_name, header_value = nil)
                if header_value
                  where('request_headers LIKE ?', "%\"#{header_name}\":\"#{header_value}\"%")
                else
                  where('request_headers LIKE ?', "%\"#{header_name}\":%")
                end
              end

              private

                def build_create_table_sql
                  <<~SQL.squish
                    CREATE TABLE IF NOT EXISTS outbound_request_logs (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      http_method TEXT NOT NULL,
                      url TEXT NOT NULL,
                      request_headers TEXT DEFAULT '{}',
                      request_body TEXT,
                      status_code INTEGER NOT NULL,
                      response_headers TEXT DEFAULT '{}',
                      response_body TEXT,
                      duration_ms REAL,
                      loggable_type TEXT,
                      loggable_id INTEGER,
                      metadata TEXT DEFAULT '{}',
                      created_at TEXT
                    )
                  SQL
                end

                def build_indexes_sql
                  [
                    'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_created_at ON outbound_request_logs(created_at)',
                    'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_status_code ON outbound_request_logs(status_code)',
                    'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_url ON outbound_request_logs(url)',
                    'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_http_method ON outbound_request_logs(http_method)',
                    'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_loggable ON outbound_request_logs(loggable_type, loggable_id)'
                  ]
                end

                def optimize_for_sqlite(log_data)
                  # For SQLite, ensure JSON fields are properly serialized
                  %i[request_headers request_body response_headers response_body metadata].each do |field|
                    log_data[field] = serialize_json_field(log_data[field]) if log_data[field]
                  end
                  log_data
                end

                def serialize_json_field(value)
                  return nil if value.nil?
                  return value if value.is_a?(String)

                  begin
                    value.to_json
                  rescue StandardError
                    value.to_s
                  end
                end
            end
          end

          # Assign the class to a constant to give it a name
          OutboundHTTPLogger::DatabaseAdapters.const_set(class_name, klass)

          klass
        end
    end
  end
end
