# frozen_string_literal: true

require 'active_record'

module OutboundHttpLogger
  module DatabaseAdapters
    module PostgresqlAdapter
      extend ActiveSupport::Concern

      included do
        # PostgreSQL-specific scopes and methods
        class << self

          # PostgreSQL-specific text search with JSONB support
          def apply_text_search(scope, q, original_query)
            scope.where(
              'LOWER(url) LIKE ? OR request_body::text ILIKE ? OR response_body::text ILIKE ?',
              q, "%#{original_query}%", "%#{original_query}%"
            )
          end

          # PostgreSQL JSONB-specific scopes
          def with_response_containing(key, value)
            where("response_body @> ?", { key => value }.to_json)
          end

          def with_request_containing(key, value)
            where("request_body @> ?", { key => value }.to_json)
          end

          def with_metadata_containing(key, value)
            where("metadata @> ?", { key => value }.to_json)
          end

          # PostgreSQL-specific performance queries
          def with_response_header(header_name, header_value = nil)
            if header_value
              where("response_headers @> ?", { header_name => header_value }.to_json)
            else
              where("response_headers ? ?", header_name)
            end
          end

          def with_request_header(header_name, header_value = nil)
            if header_value
              where("request_headers @> ?", { header_name => header_value }.to_json)
            else
              where("request_headers ? ?", header_name)
            end
          end

          private

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

        def build_create_table_sql
          <<~SQL
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
        end

        def build_indexes_sql
          [
            # Essential indexes for append-only logging (minimal set)
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_created_at ON outbound_request_logs (created_at)",
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_loggable ON outbound_request_logs (loggable_type, loggable_id)",

            # PostgreSQL-specific JSONB indexes for advanced querying
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_url_gin ON outbound_request_logs USING gin (url gin_trgm_ops)",
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_request_headers_gin ON outbound_request_logs USING gin (request_headers)",
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_response_headers_gin ON outbound_request_logs USING gin (response_headers)",
            "CREATE INDEX IF NOT EXISTS idx_outbound_logs_metadata_gin ON outbound_request_logs USING gin (metadata)"
          ]
        end
      end
    end
  end
end
