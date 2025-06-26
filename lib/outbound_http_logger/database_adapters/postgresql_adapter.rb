# frozen_string_literal: true

require_relative 'base_adapter'

module OutboundHttpLogger
  module DatabaseAdapters
    class PostgresqlAdapter < BaseAdapter
      # Check if PostgreSQL gem is available
      def adapter_available?
        @adapter_available ||= begin
          require 'pg'
          true
        rescue LoadError
          OutboundHttpLogger.configuration.get_logger&.warn('pg gem not available. PostgreSQL logging disabled.') if @database_url.present?
          false
        end
      end

      # Establish connection to PostgreSQL database
      def establish_connection
        return unless adapter_available?

        # Parse the database URL
        config = parse_database_url

        # Configure the connection for Rails multiple database support
        # This adds the configuration and establishes the connection
        env_name = defined?(Rails) ? Rails.env : 'test'
        ActiveRecord::Base.configurations.configurations << ActiveRecord::DatabaseConfigurations::HashConfig.new(
          env_name,
          connection_name.to_s,
          config
        )

        # Establish the connection in the connection handler
        ActiveRecord::Base.connection_handler.establish_connection(config, owner_name: connection_name.to_s)
      end

      # Get the model class for PostgreSQL
      def model_class
        @model_class ||= create_model_class
      end

      private

        def parse_database_url
          uri = URI.parse(@database_url)

          {
            'adapter' => 'postgresql',
            'host' => uri.host,
            'port' => uri.port || 5432,
            'database' => uri.path[1..], # Remove leading slash
            'username' => uri.user,
            'password' => uri.password,
            'pool' => 5,
            'timeout' => 5000,
            'encoding' => 'unicode'
          }.compact
        end

        def create_model_class
          adapter_connection_name = connection_name

          # Create a named class to avoid "Anonymous class is not allowed" error
          class_name = "PostgresqlOutboundRequestLog#{adapter_connection_name.to_s.camelize}"

          # Remove existing class if it exists
          OutboundHttpLogger::DatabaseAdapters.send(:remove_const, class_name) if OutboundHttpLogger::DatabaseAdapters.const_defined?(class_name)

          # Create the new class that inherits from the main model
          klass = Class.new(OutboundHttpLogger::Models::OutboundRequestLog) do
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
              Rails.logger&.error "OutboundHttpLogger: Cannot retrieve connection '#{@adapter_connection_name}': #{e.message}"
              raise
            end

            class << self
              def log_request(method, url, request_data = {}, response_data = {}, duration_seconds = 0, options = {})
                return nil unless OutboundHttpLogger.enabled?
                return nil unless OutboundHttpLogger.configuration.should_log_url?(url)

                # Check content type filtering
                content_type = response_data[:headers]&.[]('content-type') ||
                               response_data[:headers]&.[]('Content-Type')
                return nil unless OutboundHttpLogger.configuration.should_log_content_type?(content_type)

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
                  request_headers: OutboundHttpLogger.configuration.filter_headers(request_data[:headers] || {}),
                  request_body: OutboundHttpLogger.configuration.filter_body(request_data[:body]),
                  response_headers: OutboundHttpLogger.configuration.filter_headers(response_data[:headers] || {}),
                  response_body: OutboundHttpLogger.configuration.filter_body(response_data[:body]),
                  duration_ms: duration_ms,
                  loggable: request_data[:loggable] || thread_loggable,
                  metadata: merged_metadata
                }

                # For PostgreSQL, we can store JSON objects directly in JSONB columns
                log_data = prepare_json_data_for_postgresql(log_data)

                create!(log_data)
              rescue StandardError => e
                # Failsafe: Never let logging errors break the HTTP request
                logger = OutboundHttpLogger.configuration.get_logger
                logger&.error("OutboundHttpLogger: Failed to log request: #{e.class}: #{e.message}")
                nil
              end

              # PostgreSQL-specific text search with JSONB support
              def apply_text_search(scope, q, original_query)
                scope.where(
                  'LOWER(url) LIKE ? OR request_body::text ILIKE ? OR response_body::text ILIKE ?',
                  q, "%#{original_query}%", "%#{original_query}%"
                )
              end

              # PostgreSQL JSONB-specific scopes
              def with_response_containing(key, value)
                where('response_body @> ?', { key => value }.to_json)
              end

              def with_request_containing(key, value)
                where('request_body @> ?', { key => value }.to_json)
              end

              def with_metadata_containing(key, value)
                where('metadata @> ?', { key => value }.to_json)
              end

              # PostgreSQL-specific performance queries
              def with_response_header(header_name, header_value = nil)
                if header_value
                  where('response_headers @> ?', { header_name => header_value }.to_json)
                else
                  where('response_headers ? ?', header_name)
                end
              end

              def with_request_header(header_name, header_value = nil)
                if header_value
                  where('request_headers @> ?', { header_name => header_value }.to_json)
                else
                  where('request_headers ? ?', header_name)
                end
              end

              def prepare_json_data_for_postgresql(log_data)
                # Convert JSON strings back to objects for JSONB storage
                %i[request_headers request_body response_headers response_body metadata].each do |field|
                  next unless log_data[field].is_a?(String) && log_data[field].present?

                  begin
                    log_data[field] = JSON.parse(log_data[field])
                  rescue JSON::ParserError
                    # Keep as string if not valid JSON
                  end
                end

                log_data
              end
            end
          end

          # Assign the class to a constant to give it a name
          OutboundHttpLogger::DatabaseAdapters.const_set(class_name, klass)

          klass
        end

        def build_create_table_sql
          <<~SQL.squish
            CREATE TABLE IF NOT EXISTS outbound_request_logs (
              id BIGSERIAL PRIMARY KEY,
              http_method VARCHAR(10) NOT NULL,
              url TEXT NOT NULL,
              request_headers JSONB DEFAULT '{}',
              request_body JSONB,
              status_code INTEGER NOT NULL,
              response_headers JSONB DEFAULT '{}',
              response_body JSONB,
              duration_ms DECIMAL(10,2),
              loggable_type VARCHAR(255),
              loggable_id BIGINT,
              metadata JSONB DEFAULT '{}',
              created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            )
          SQL
        end

        def create_indexes_sql
          [
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_created_at ON outbound_request_logs(created_at)',
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_status_code ON outbound_request_logs(status_code)',
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_url ON outbound_request_logs(url)',
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_http_method ON outbound_request_logs(http_method)',
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_loggable ON outbound_request_logs(loggable_type, loggable_id)',
            # PostgreSQL-specific JSONB indexes for advanced querying
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_request_headers_gin ON outbound_request_logs USING gin (request_headers)',
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_response_headers_gin ON outbound_request_logs USING gin (response_headers)',
            'CREATE INDEX IF NOT EXISTS idx_outbound_request_logs_metadata_gin ON outbound_request_logs USING gin (metadata)'
          ]
        end
    end
  end
end
